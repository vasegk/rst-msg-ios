import AVFoundation
import AudioToolbox
import Foundation
import UIKit
import WebRTC

/// Звонок один на один (как js/calls.js): сигналы — кадры rtc_signaling
/// {type: call_invite/call_accepted/call_rejected/call_busy/call_hangup/
/// offer/answer/candidate/camera_on/camera_off/...}, медиа — WebRTC,
/// ретранслятор — /api/turn-credentials. Запись в журнал пишет звонивший.
@MainActor
@Observable
final class CallService {
    enum Phase: Equatable {
        case idle
        /// Звоним, ждём ответа.
        case outgoing
        /// Нам звонят.
        case incoming
        /// Ответили, устанавливаем связь.
        case connecting
        case active
    }

    private(set) var phase: Phase = .idle
    private(set) var peer = ""
    private(set) var statusText = ""
    private(set) var connectedAt: Date?
    private(set) var muted = false
    private(set) var speaker = false
    private(set) var cameraOn = false
    private(set) var remoteCamera = false
    private(set) var remoteScreen = false
    private(set) var frontCamera = true
    /// Окно звонка свёрнуто — по приложению можно ходить, сверху плашка.
    var minimized = false
    /// Только что закончился: короткое сообщение (не ответил, занят…).
    var notice: String?
    private(set) var localVideo: RTCVideoTrack?
    private(set) var remoteVideo: RTCVideoTrack?

    static let callTimeout: UInt64 = 50
    static let reconnectGrace: UInt64 = 8
    private static let fallbackIce = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]

    @ObservationIgnored private let api: RstApi
    @ObservationIgnored private let socket: RstWebSocket
    @ObservationIgnored private var subscription: UUID?
    @ObservationIgnored private var factoryStorage: RTCPeerConnectionFactory?
    @ObservationIgnored private var pc: RTCPeerConnection?
    @ObservationIgnored private let pcDelegate = PeerDelegate()
    @ObservationIgnored private var iceServers: [RTCIceServer] = []
    @ObservationIgnored private var localAudio: RTCAudioTrack?
    @ObservationIgnored private var videoSource: RTCVideoSource?
    @ObservationIgnored private var capturer: RTCCameraVideoCapturer?
    @ObservationIgnored private var pendingCandidates: [RTCIceCandidate] = []
    @ObservationIgnored private var isCaller = false
    @ObservationIgnored private var makingOffer = false
    @ObservationIgnored private var wantVideo = false
    @ObservationIgnored private var record: (peer: String, video: Bool, status: String)?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var ringTask: Task<Void, Never>?

    init(api: RstApi, socket: RstWebSocket) {
        self.api = api
        self.socket = socket
        pcDelegate.owner = self
        subscription = socket.subscribe(owner: self) { [weak self] event in
            guard case .other(let action, let payload) = event, action == "rtc_signaling",
                  let sender = payload["sender"]?.stringValue, let data = payload["data"] else { return }
            self?.handleSignal(from: sender, data)
        }
    }

    private var factory: RTCPeerConnectionFactory {
        if let factoryStorage { return factoryStorage }
        RTCInitializeSSL()
        let made = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                            decoderFactory: RTCDefaultVideoDecoderFactory())
        factoryStorage = made
        return made
    }

    var isBusy: Bool { phase != .idle }
    var hasVideo: Bool { cameraOn || remoteCamera || remoteScreen }

    // MARK: - Исходящий

    func call(_ username: String, video: Bool) {
        guard phase == .idle else { return }
        peer = username
        isCaller = true
        wantVideo = video
        phase = .outgoing
        minimized = false
        statusText = "Доступ к устройствам…"
        Task {
            do {
                try await prepareMedia(video: video)
            } catch {
                notice = errorText(error)
                cleanup()
                return
            }
            await loadIce()
            guard phase == .outgoing else { return }
            record = (username, cameraOn, "missed")
            statusText = "Ожидание ответа…"
            signal(["type": .string("call_invite"), "video": .bool(cameraOn)])
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.callTimeout * 1_000_000_000)
                guard let self, !Task.isCancelled, self.phase == .outgoing else { return }
                self.notice = "Собеседник не ответил"
                self.hangup()
            }
        }
    }

    // MARK: - Входящий

    func answer() {
        guard phase == .incoming else { return }
        stopRinging()
        phase = .connecting
        statusText = "Подключение устройств…"
        Task {
            do {
                try await prepareMedia(video: wantVideo)
            } catch {
                notice = errorText(error)
                signal(["type": .string("call_rejected")])
                cleanup()
                return
            }
            await loadIce()
            // Своё состояние камеры — сразу: иначе звонивший не узнает о ней
            signal(["type": .string("call_accepted"), "video": .bool(cameraOn)])
        }
    }

    func decline() {
        guard phase == .incoming else { return }
        signal(["type": .string("call_rejected")])
        cleanup()
    }

    func hangup() {
        if phase != .idle { signal(["type": .string("call_hangup")]) }
        cleanup()
    }

    // MARK: - Кнопки

    func toggleMute() {
        muted.toggle()
        localAudio?.isEnabled = !muted
    }

    func toggleSpeaker() {
        speaker.toggle()
        setSpeaker(speaker)
    }

    func toggleCamera() {
        if cameraOn {
            capturer?.stopCapture()
            localVideo?.isEnabled = false
            cameraOn = false
            signal(["type": .string("camera_off")])
            return
        }
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                notice = "Нет доступа к камере. Разрешите её в Настройках → RST."
                return
            }
            let added = localVideo == nil
            if added { addVideoTrack() }
            startCapture()
            localVideo?.isEnabled = true
            cameraOn = true
            if added { await makeOffer() }
            signal(["type": .string("camera_on")])
        }
    }

    func switchCamera() {
        frontCamera.toggle()
        if cameraOn { startCapture() }
    }

    // MARK: - Медиа

    private func prepareMedia(video: Bool) async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw CryptoError("Нет доступа к микрофону. Разрешите его в Настройках → RST.")
        }
        configureAudio()
        let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        localAudio = factory.audioTrack(with: audioSource, trackId: "audio0")
        if video, await AVCaptureDevice.requestAccess(for: .video) {
            addVideoTrack()
            startCapture()
            cameraOn = true
            speaker = true
            setSpeaker(true)
        }
    }

    private func addVideoTrack() {
        let source = factory.videoSource()
        videoSource = source
        capturer = RTCCameraVideoCapturer(delegate: source)
        let track = factory.videoTrack(with: source, trackId: "video0")
        localVideo = track
        if let pc { pc.add(track, streamIds: ["stream0"]) }
    }

    private func startCapture() {
        guard let capturer else { return }
        let position: AVCaptureDevice.Position = frontCamera ? .front : .back
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let device = devices.first(where: { $0.position == position }) ?? devices.first else { return }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let fitting = formats.filter { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <= 1280 }
        guard let format = fitting.last ?? formats.first else { return }
        let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        capturer.stopCapture()
        capturer.startCapture(with: device, format: format, fps: Int(min(30, maxRate)))
    }

    private func configureAudio() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.setCategory(AVAudioSession.Category.playAndRecord, with: [.allowBluetooth, .allowBluetoothA2DP])
        try? session.setMode(AVAudioSession.Mode.voiceChat)
        try? session.setActive(true)
        session.unlockForConfiguration()
    }

    private func setSpeaker(_ on: Bool) {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.overrideOutputAudioPort(on ? .speaker : .none)
        session.unlockForConfiguration()
    }

    /// Ретранслятор — перед звонком: пропуск живёт час.
    private func loadIce() async {
        if let list = try? await api.turnCredentials().iceServers, !list.isEmpty {
            iceServers = list.map { RTCIceServer(urlStrings: $0.urlList, username: $0.username, credential: $0.credential) }
        } else {
            iceServers = Self.fallbackIce
        }
    }

    private func makePeerConnection() -> RTCPeerConnection? {
        let config = RTCConfiguration()
        config.iceServers = iceServers.isEmpty ? Self.fallbackIce : iceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                              optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue])
        guard let made = factory.peerConnection(with: config, constraints: constraints, delegate: pcDelegate) else { return nil }
        if let localAudio { made.add(localAudio, streamIds: ["stream0"]) }
        if let localVideo { made.add(localVideo, streamIds: ["stream0"]) }
        pc = made
        return made
    }

    private static var receiveConstraints: RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true"],
                            optionalConstraints: nil)
    }

    // MARK: - Сигналы

    private func signal(_ data: [String: JSONValue]) {
        guard !peer.isEmpty else { return }
        _ = socket.sendObject(["action": .string("rtc_signaling"), "receiver": .string(peer), "data": .object(data)])
    }

    private func handleSignal(from sender: String, _ data: JSONValue) {
        let type = data["type"]?.stringValue ?? ""
        // Всё, кроме приглашения, — только от того, с кем говорим
        if type != "call_invite" && sender != peer { return }
        switch type {
        case "call_invite":
            guard phase == .idle else {
                _ = socket.sendObject(["action": .string("rtc_signaling"), "receiver": .string(sender),
                                       "data": .object(["type": .string("call_busy")])])
                return
            }
            peer = sender
            isCaller = false
            remoteCamera = data["video"]?.bool == true
            wantVideo = remoteCamera
            phase = .incoming
            minimized = false
            statusText = remoteCamera ? "Входящий видеозвонок…" : "Входящий аудиозвонок…"
            startRinging()
        case "call_busy":
            guard phase == .outgoing else { return }
            record?.status = "busy"
            notice = "Собеседник занят"
            cleanup()
        case "call_denied":
            record?.status = "failed"
            notice = "Этот человек не принимает звонки от вас"
            cleanup()
        case "call_rejected":
            record?.status = "declined"
            if phase != .incoming { notice = "Собеседник отклонил вызов" }
            cleanup()
        case "call_accepted":
            guard phase == .outgoing else { return }
            timeoutTask?.cancel()
            remoteCamera = data["video"]?.bool == true
            phase = .connecting
            statusText = "Соединение защищено…"
            Task { await makeOffer() }
        case "call_hangup":
            cleanup()
        case "offer":
            if let sdp = Self.sessionDescription(data["sdp"]) { Task { await handleOffer(sdp) } }
        case "answer":
            guard let pc, pc.signalingState == .haveLocalOffer, let sdp = Self.sessionDescription(data["sdp"]) else { return }
            pc.setRemoteDescription(sdp) { [weak self] _ in
                Task { @MainActor in self?.flushCandidates() }
            }
        case "candidate":
            guard let c = Self.candidate(data["candidate"]) else { return }
            if let pc, pc.remoteDescription != nil {
                pc.add(c) { _ in }
            } else {
                pendingCandidates.append(c)
            }
        case "camera_on":
            remoteCamera = true
        case "camera_off":
            remoteCamera = false
        case "screen_on":
            remoteScreen = true
        case "screen_off":
            remoteScreen = false
            remoteCamera = data["camera"]?.bool == true
        default:
            break
        }
    }

    private func makeOffer() async {
        guard let pc = pc ?? makePeerConnection() else { return }
        makingOffer = true
        defer { makingOffer = false }
        do {
            let offer = try await pc.offer(for: Self.receiveConstraints)
            try await pc.setLocalDescription(offer)
            signal(["type": .string("offer"), "sdp": Self.json(offer)])
        } catch {
            // Предложение не сложилось — звонок оборвётся по таймеру
        }
    }

    private func handleOffer(_ sdp: RTCSessionDescription) async {
        if pc == nil {
            statusText = "Установка связи…"
            _ = makePeerConnection()
        }
        guard let pc else { return }
        // Встречные предложения: уступает принявший звонок
        let collision = makingOffer || pc.signalingState != .stable
        if collision && isCaller { return }
        do {
            try await pc.setRemoteDescription(sdp)
            flushCandidates()
            let answer = try await pc.answer(for: Self.receiveConstraints)
            try await pc.setLocalDescription(answer)
            signal(["type": .string("answer"), "sdp": Self.json(answer)])
        } catch {
            // Ответ не сложился — звонок оборвётся по таймеру соединения
        }
    }

    private func flushCandidates() {
        guard let pc else { return }
        for c in pendingCandidates { pc.add(c) { _ in } }
        pendingCandidates = []
    }

    // MARK: - События соединения (с очереди WebRTC)

    fileprivate func didGenerate(_ candidate: RTCIceCandidate) {
        signal(["type": .string("candidate"), "candidate": .object([
            "candidate": .string(candidate.sdp),
            "sdpMid": candidate.sdpMid.map { .string($0) } ?? .null,
            "sdpMLineIndex": .number(Double(candidate.sdpMLineIndex)),
        ])])
    }

    fileprivate func didAddRemote(_ track: RTCMediaStreamTrack) {
        if let video = track as? RTCVideoTrack { remoteVideo = video }
    }

    fileprivate func connectionChanged(_ state: RTCPeerConnectionState) {
        switch state {
        case .connected:
            reconnectTask?.cancel()
            reconnectTask = nil
            if connectedAt == nil { connectedAt = Date() }
            phase = .active
            statusText = ""
        case .disconnected:
            // Связь часто пропадает на секунды при смене сети и возвращается сама
            guard reconnectTask == nil else { return }
            statusText = "Связь потеряна, восстанавливаем…"
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.reconnectGrace * 1_000_000_000)
                guard let self, !Task.isCancelled, self.pc?.connectionState != .connected else { return }
                self.notice = "Связь потеряна"
                self.hangup()
            }
        case .failed:
            record?.status = "failed"
            notice = "Не удалось установить связь"
            hangup()
        default:
            break
        }
    }

    // MARK: - Конец

    private func cleanup() {
        timeoutTask?.cancel()
        reconnectTask?.cancel()
        timeoutTask = nil
        reconnectTask = nil
        stopRinging()
        finishRecord()
        capturer?.stopCapture()
        capturer = nil
        videoSource = nil
        localVideo = nil
        localAudio = nil
        remoteVideo = nil
        pc?.close()
        pc = nil
        pendingCandidates = []
        phase = .idle
        peer = ""
        statusText = ""
        connectedAt = nil
        muted = false
        speaker = false
        cameraOn = false
        remoteCamera = false
        remoteScreen = false
        minimized = false
        isCaller = false
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.setActive(false)
        session.unlockForConfiguration()
    }

    /// Запись в журнал звонков — только у звонившего.
    private func finishRecord() {
        guard let rec = record else { return }
        record = nil
        let duration = connectedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        let status = connectedAt != nil ? "answered" : rec.status
        let api = self.api
        Task { try? await api.logCall(CallLogRequest(peer: rec.peer, status: status, duration: duration, video: rec.video)) }
    }

    // MARK: - Звонок звенит

    private func startRinging() {
        ringTask?.cancel()
        ringTask = Task {
            while !Task.isCancelled {
                AudioServicesPlaySystemSound(1151)
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopRinging() {
        ringTask?.cancel()
        ringTask = nil
    }

    // MARK: - JSON ↔ WebRTC

    static func json(_ sdp: RTCSessionDescription) -> JSONValue {
        .object(["type": .string(RTCSessionDescription.string(for: sdp.type)), "sdp": .string(sdp.sdp)])
    }

    static func sessionDescription(_ value: JSONValue?) -> RTCSessionDescription? {
        guard let value, let sdp = value["sdp"]?.stringValue, let type = value["type"]?.stringValue else { return nil }
        let kind: RTCSdpType
        switch type {
        case "offer": kind = .offer
        case "answer": kind = .answer
        case "pranswer": kind = .prAnswer
        default: return nil
        }
        return RTCSessionDescription(type: kind, sdp: sdp)
    }

    static func candidate(_ value: JSONValue?) -> RTCIceCandidate? {
        guard let value, let sdp = value["candidate"]?.stringValue, !sdp.isEmpty else { return nil }
        let index = Int32(value["sdpMLineIndex"]?.double ?? 0)
        return RTCIceCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: value["sdpMid"]?.stringValue)
    }
}

/// Делегат соединения: WebRTC зовёт его со своей очереди.
private final class PeerDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    weak var owner: CallService?

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor [weak self] in self?.owner?.didGenerate(candidate) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor [weak self] in self?.owner?.connectionChanged(newState) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver,
                        streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track else { return }
        Task { @MainActor [weak self] in self?.owner?.didAddRemote(track) }
    }
}
