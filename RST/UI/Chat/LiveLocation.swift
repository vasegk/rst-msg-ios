import CoreLocation
import Foundation
import Observation

/// Координаты устройства: одна точка или поток обновлений (пока открыто приложение).
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var oneShot: [CheckedContinuation<CLLocation, Error>] = []
    var onUpdate: (CLLocation) -> Void = { _ in }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    private func ensureAccess() throws {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            throw CryptoError("Нет доступа к геопозиции. Разрешите его в Настройках → RST.")
        default:
            break
        }
    }

    /// Одна точка.
    func current() async throws -> CLLocation {
        try ensureAccess()
        return try await withCheckedThrowingContinuation { continuation in
            oneShot.append(continuation)
            manager.requestLocation()
        }
    }

    func start() throws {
        try ensureAccess()
        manager.startUpdatingLocation()
    }

    func stop() { manager.stopUpdatingLocation() }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in
            let waiting = self.oneShot
            self.oneShot.removeAll()
            waiting.forEach { $0.resume(returning: last) }
            self.onUpdate(last)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let waiting = self.oneShot
            self.oneShot.removeAll()
            waiting.forEach { $0.resume(throwing: CryptoError("Не удалось определить местоположение")) }
        }
    }
}

/// Отправка местоположения (веб: chat-window.js sendLocation, live-location.js).
///
/// Текущее место — обычный текст со ссылкой на карту. Трансляция — сообщение
/// application/x-rst-live-location с конвертом g; новые точки — кадром
/// live_location раз в 10 с или при сдвиге больше 30 м; срок вышел или
/// «Остановить» — последняя точка со stopped. Только пока приложение открыто.
@MainActor
@Observable
final class LiveLocationSharing {
    static let shared = LiveLocationSharing()
    static let liveText = "📍 Геопозиция в реальном времени"

    struct Session {
        let chatId: String
        var messageId: Int64?
        let until: Date
        var lastSent: CLLocation?
        var lastSentAt: Date = .distantPast
    }

    private(set) var sessions: [String: Session] = [:]
    @ObservationIgnored private let provider = LocationProvider()
    @ObservationIgnored private var services: Services?
    @ObservationIgnored private var subscription: UUID?
    @ObservationIgnored private var timer: Timer?

    private init() {
        provider.onUpdate = { [weak self] location in self?.tick(location) }
    }

    func isSharing(messageId: Int64) -> Bool { sessions.values.contains { $0.messageId == messageId } }

    static func mapLink(lat: Double, lon: Double) -> String {
        let a = String(format: "%.5f", lat), b = String(format: "%.5f", lon)
        return "https://www.openstreetmap.org/?mlat=\(a)&mlon=\(b)#map=17/\(a)/\(b)"
    }

    /// Одна точка — текстом со ссылкой на карту, как в вебе.
    func sendCurrent(chatId: String, services: Services) async throws {
        let location = try await provider.current()
        let text = "📍 Местоположение\n" + Self.mapLink(lat: location.coordinate.latitude, lon: location.coordinate.longitude)
        try await services.messages.sendText(chatId, text: text)
    }

    /// Трансляция на duration секунд (15 мин / 1 ч / 8 ч).
    func start(chatId: String, duration: TimeInterval, services: Services) async throws {
        self.services = services
        let location = try await provider.current()
        let until = Date().addingTimeInterval(duration)
        sessions[chatId] = Session(chatId: chatId, messageId: nil, until: until, lastSent: location, lastSentAt: Date())
        listenForEcho(services)
        let keys = try await services.messages.sendKeys(for: chatId)
        let content = try MessageCrypto.encryptEnvelope(keys, envelope(location, until: until, stopped: false))
        guard services.socket.sendMessage(receiver: chatId, content: content, fileType: MessageDto.fileTypeLiveLocation) else {
            sessions[chatId] = nil
            throw NotConnectedError()
        }
        try provider.start()
        startTimer()
    }

    func stop(chatId: String) {
        guard let session = sessions[chatId] else { return }
        sessions[chatId] = nil
        if let location = session.lastSent, let id = session.messageId {
            Task { await send(location, session: session, messageId: id, stopped: true) }
        }
        if sessions.isEmpty {
            provider.stop()
            timer?.invalidate()
            timer = nil
        }
    }

    func stop(messageId: Int64) {
        if let chat = sessions.values.first(where: { $0.messageId == messageId })?.chatId { stop(chatId: chat) }
    }

    private func envelope(_ location: CLLocation, until: Date, stopped: Bool) -> Envelope {
        var env = Envelope(text: Self.liveText)
        env.geo = LiveGeo(lat: location.coordinate.latitude, lon: location.coordinate.longitude,
                          acc: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
                          until: Int64(until.timeIntervalSince1970 * 1000),
                          ts: Int64(Date().timeIntervalSince1970 * 1000), stopped: stopped ? true : nil)
        return env
    }

    /// Номер сообщения трансляции приходит эхом new_msg.
    private func listenForEcho(_ services: Services) {
        guard subscription == nil else { return }
        subscription = services.socket.subscribe(owner: self) { [weak self] event in
            guard let self, case .newMessage(let dto, let receiver) = event,
                  dto.fileType == MessageDto.fileTypeLiveLocation, dto.sender == services.me,
                  var session = self.sessions[receiver], session.messageId == nil else { return }
            session.messageId = dto.id
            self.sessions[receiver] = session
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.periodic() }
        }
    }

    /// Раз в 10 с — точка (и проверка срока).
    private func periodic() {
        for (chatId, session) in sessions {
            if Date() >= session.until {
                stop(chatId: chatId)
            } else if let location = session.lastSent, let id = session.messageId,
                      Date().timeIntervalSince(session.lastSentAt) >= 10 {
                Task { await send(location, session: session, messageId: id, stopped: false) }
            }
        }
    }

    /// Сдвиг больше 30 м — точка сразу (но не чаще раза в 3 с).
    private func tick(_ location: CLLocation) {
        for (chatId, session) in sessions {
            var updated = session
            let moved = session.lastSent.map { location.distance(from: $0) > 30 } ?? true
            updated.lastSent = location
            sessions[chatId] = updated
            if moved, let id = session.messageId, Date().timeIntervalSince(session.lastSentAt) >= 3 {
                Task { await send(location, session: updated, messageId: id, stopped: false) }
            }
        }
    }

    private func send(_ location: CLLocation, session: Session, messageId: Int64, stopped: Bool) async {
        guard let services else { return }
        guard let keys = try? await services.messages.sendKeys(for: session.chatId),
              let content = try? MessageCrypto.encryptEnvelope(keys, envelope(location, until: session.until, stopped: stopped)) else { return }
        if services.socket.sendLiveLocation(messageId: messageId, content: content), !stopped,
           var current = sessions[session.chatId] {
            current.lastSentAt = Date()
            sessions[session.chatId] = current
        }
    }
}
