import AVFoundation
import Foundation
import WebRTC

/// Общая фабрика WebRTC и настройки звука для звонков.
@MainActor
enum RTCShared {
    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()
    static let fallbackIce = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]

    static func iceServers(_ api: RstApi) async -> [RTCIceServer] {
        if let list = try? await api.turnCredentials().iceServers, !list.isEmpty {
            return list.map { RTCIceServer(urlStrings: $0.urlList, username: $0.username, credential: $0.credential) }
        }
        return fallbackIce
    }

    static var receiveConstraints: RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true"],
                            optionalConstraints: nil)
    }

    static func configureAudio() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.setCategory(AVAudioSession.Category.playAndRecord, with: [.allowBluetooth, .allowBluetoothA2DP])
        try? session.setMode(AVAudioSession.Mode.voiceChat)
        try? session.setActive(true)
        session.unlockForConfiguration()
    }

    static func setSpeaker(_ on: Bool) {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.overrideOutputAudioPort(on ? .speaker : .none)
        session.unlockForConfiguration()
    }

    static func releaseAudio() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.setActive(false)
        session.unlockForConfiguration()
    }
}

/// Групповой звонок (как js/group-calls.js): каждый соединяется с каждым
/// напрямую, сервер только пересылает сигналы — разговор ему недоступен.
/// Соединение заводит пришедший последним (gcall_peers); при встречных
/// предложениях уступает тот, чей ник меньше по алфавиту.
@MainActor
@Observable
final class GroupCallService {
    struct Peer: Identifiable {
        let username: String
        var camera = false
        var screen = false
        var mic = true
        var video: RTCVideoTrack?
        var trouble = false
        var id: String { username }
    }

    final class Connection {
        let pc: RTCPeerConnection
        let delegate: GroupPeerDelegate
        var queue: [RTCIceCandidate] = []
        var videoSender: RTCRtpSender?
        var makingOffer = false
        init(pc: RTCPeerConnection, delegate: GroupPeerDelegate) {
            self.pc = pc
            self.delegate = delegate
        }
    }

    /// Чат открытого звонка; nil — звонка нет.
    private(set) var chatId: String?
    private(set) var peers: [Peer] = []
    private(set) var muted = false
    private(set) var cameraOn = false
    private(set) var speaker = true
    private(set) var startedAt: Date?
    private(set) var localVideo: RTCVideoTrack?
    var minimized = false
    var notice: String?
    /// Кто сейчас в звонке, по чатам (gcall_state) — для плашки «идёт звонок».
    private(set) var rooms: [String: [String]] = [:]

    @ObservationIgnored private let api: RstApi
    @ObservationIgnored private let socket: RstWebSocket
    @ObservationIgnored private let me: () -> String
    @ObservationIgnored private var subscription: UUID?
    @ObservationIgnored private var connections: [String: Connection] = [:]
    @ObservationIgnored private var iceServers: [RTCIceServer] = []
    @ObservationIgnored private var localAudio: RTCAudioTrack?
    @ObservationIgnored private var capturer: RTCCameraVideoCapturer?

    init(api: RstApi, socket: RstWebSocket, me: @escaping () -> String) {
        self.api = api
        self.socket = socket
        self.me = me
        subscription = socket.subscribe(owner: self) { [weak self] event in
            guard case .other(let action, let payload) = event, action.hasPrefix("gcall_") else { return }
            self?.handle(action, payload)
        }
    }

    var isActive: Bool { chatId != nil }

    func participants(in chat: String) -> [String] { rooms[chat] ?? [] }

    // MARK: - Войти и выйти

    func join(_ chat: String) {
        guard chatId == nil else { return }
        chatId = chat
        minimized = false
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                notice = "Нет доступа к микрофону. Разрешите его в Настройках → RST."
                teardown()
                return
            }
            RTCShared.configureAudio()
            RTCShared.setSpeaker(true)
            let source = RTCShared.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
            localAudio = RTCShared.factory.audioTrack(with: source, trackId: "gaudio0")
            iceServers = await RTCShared.iceServers(api)
            guard chatId == chat else { return }
            startedAt = Date()
            _ = socket.sendObject(["action": .string("gcall_join"), "chat_id": .string(chat)])
        }
    }

    func leave() {
        guard let chatId else { return }
        _ = socket.sendObject(["action": .string("gcall_leave"), "chat_id": .string(chatId)])
        teardown()
    }

    private func teardown() {
        for c in connections.values { c.pc.close() }
        connections = [:]
        peers = []
        capturer?.stopCapture()
        capturer = nil
        localVideo = nil
        localAudio = nil
        cameraOn = false
        muted = false
        speaker = true
        startedAt = nil
        minimized = false
        chatId = nil
        RTCShared.releaseAudio()
    }

    // MARK: - Кнопки

    func toggleMute() {
        muted.toggle()
        localAudio?.isEnabled = !muted
        sendMediaState()
    }

    func toggleSpeaker() {
        speaker.toggle()
        RTCShared.setSpeaker(speaker)
    }

    func toggleCamera() {
        Task {
            if cameraOn {
                await capturer?.stopCapture()
                cameraOn = false
                for c in connections.values { c.videoSender?.track = nil }
                sendMediaState()
                return
            }
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                notice = "Нет доступа к камере. Разрешите её в Настройках → RST."
                return
            }
            startCamera()
            // Одну дорожку — всем: у кого отправитель есть — подменяем, у кого нет — договариваемся заново
            for (name, c) in connections {
                if let sender = c.videoSender {
                    sender.track = localVideo
                } else if let localVideo {
                    c.videoSender = c.pc.add(localVideo, streamIds: ["gstream0"])
                    await offer(to: name, c)
                }
            }
            sendMediaState()
        }
    }

    private func startCamera() {
        if localVideo == nil {
            let source = RTCShared.factory.videoSource()
            capturer = RTCCameraVideoCapturer(delegate: source)
            localVideo = RTCShared.factory.videoTrack(with: source, trackId: "gvideo0")
        }
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let capturer, let device = devices.first(where: { $0.position == .front }) ?? devices.first else { return }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let small = formats.filter { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <= 640 }
        guard let format = small.last ?? formats.first else { return }
        capturer.startCapture(with: device, format: format, fps: 24)
        cameraOn = true
    }

    // MARK: - Сообщения сервера

    private func handle(_ action: String, _ payload: JSONValue) {
        let chat = payload["chat_id"]?.stringValue ?? ""
        switch action {
        case "gcall_state":
            let now = payload["participants"]?.array?.compactMap(\.stringValue) ?? []
            rooms[chat] = now.isEmpty ? nil : now
            return
        case "gcall_full":
            let limit = Int(payload["limit"]?.double ?? 0)
            notice = "В звонке уже \(limit) человек — больше не помещается"
            teardown()
            return
        default:
            break
        }
        guard chatId != nil, chat == chatId else { return }
        switch action {
        case "gcall_peers":
            for name in payload["peers"]?.array?.compactMap(\.stringValue) ?? [] where name != me() {
                Task { await connect(to: name) }
            }
        case "gcall_peer_left":
            guard let name = payload["username"]?.stringValue else { return }
            connections[name]?.pc.close()
            connections[name] = nil
            peers.removeAll { $0.username == name }
        case "gcall_signal":
            guard let sender = payload["sender"]?.stringValue, let data = payload["data"] else { return }
            handleSignal(sender, data)
        default:
            break
        }
    }

    private func handleSignal(_ sender: String, _ data: JSONValue) {
        switch data["type"]?.stringValue {
        case "offer":
            if let sdp = CallService.sessionDescription(data["sdp"]) { Task { await onOffer(sender, sdp) } }
        case "answer":
            guard let c = connections[sender], c.pc.signalingState == .haveLocalOffer,
                  let sdp = CallService.sessionDescription(data["sdp"]) else { return }
            c.pc.setRemoteDescription(sdp) { [weak self] _ in Task { @MainActor in self?.flush(sender) } }
        case "candidate":
            guard let c = connections[sender], let cand = CallService.candidate(data["candidate"]) else { return }
            if c.pc.remoteDescription != nil {
                c.pc.add(cand) { _ in }
            } else {
                c.queue.append(cand)
            }
        case "media_state":
            update(sender) {
                $0.camera = data["camera"]?.bool == true
                $0.screen = data["screen"]?.bool == true
                $0.mic = data["mic"]?.bool != false
            }
        default:
            break
        }
    }

    // MARK: - Соединения

    private func update(_ name: String, _ change: (inout Peer) -> Void) {
        if let i = peers.firstIndex(where: { $0.username == name }) { change(&peers[i]) }
    }

    private func makeConnection(_ name: String) -> Connection? {
        let config = RTCConfiguration()
        config.iceServers = iceServers.isEmpty ? RTCShared.fallbackIce : iceServers
        config.sdpSemantics = .unifiedPlan
        let delegate = GroupPeerDelegate(owner: self, username: name)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                              optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue])
        guard let pc = RTCShared.factory.peerConnection(with: config, constraints: constraints, delegate: delegate) else { return nil }
        if let localAudio { pc.add(localAudio, streamIds: ["gstream0"]) }
        let c = Connection(pc: pc, delegate: delegate)
        if cameraOn, let localVideo { c.videoSender = pc.add(localVideo, streamIds: ["gstream0"]) }
        connections[name] = c
        if !peers.contains(where: { $0.username == name }) { peers.append(Peer(username: name)) }
        return c
    }

    private func connect(to name: String) async {
        if let existing = connections[name] {
            let alive: [RTCPeerConnectionState] = [.new, .connecting, .connected]
            if alive.contains(existing.pc.connectionState) { return }
            existing.pc.close()
            connections[name] = nil
        }
        guard let c = makeConnection(name) else { return }
        await offer(to: name, c)
        sendMediaState(to: name)
    }

    private func offer(to name: String, _ c: Connection) async {
        c.makingOffer = true
        defer { c.makingOffer = false }
        do {
            let offer = try await c.pc.offer(for: RTCShared.receiveConstraints)
            try await c.pc.setLocalDescription(offer)
            signal(name, ["type": .string("offer"), "sdp": CallService.json(offer)])
        } catch {
            // Один не договорился — остальным это не мешает
        }
    }

    private func onOffer(_ sender: String, _ sdp: RTCSessionDescription) async {
        guard let c = connections[sender] ?? makeConnection(sender) else { return }
        // Встречные предложения: уступает тот, чей ник меньше по алфавиту
        let polite = me() < sender
        let collision = c.makingOffer || c.pc.signalingState != .stable
        if collision && !polite { return }
        do {
            try await c.pc.setRemoteDescription(sdp)
            flush(sender)
            let answer = try await c.pc.answer(for: RTCShared.receiveConstraints)
            try await c.pc.setLocalDescription(answer)
            signal(sender, ["type": .string("answer"), "sdp": CallService.json(answer)])
            sendMediaState(to: sender)
        } catch {
            // Ответ не сложился — плитка покажет плохую связь
        }
    }

    private func flush(_ name: String) {
        guard let c = connections[name] else { return }
        for cand in c.queue { c.pc.add(cand) { _ in } }
        c.queue = []
    }

    private func signal(_ target: String, _ data: [String: JSONValue]) {
        guard let chatId else { return }
        _ = socket.sendObject(["action": .string("gcall_signal"), "chat_id": .string(chatId),
                               "target": .string(target), "data": .object(data)])
    }

    private func sendMediaState(to name: String? = nil) {
        let state: [String: JSONValue] = ["type": .string("media_state"), "camera": .bool(cameraOn),
                                          "screen": .bool(false), "mic": .bool(!muted)]
        if let name {
            signal(name, state)
        } else {
            for peer in connections.keys { signal(peer, state) }
        }
    }

    fileprivate func didGenerate(_ candidate: RTCIceCandidate, for name: String) {
        signal(name, ["type": .string("candidate"), "candidate": .object([
            "candidate": .string(candidate.sdp),
            "sdpMid": candidate.sdpMid.map { .string($0) } ?? .null,
            "sdpMLineIndex": .number(Double(candidate.sdpMLineIndex)),
        ])])
    }

    fileprivate func didAddRemote(_ track: RTCMediaStreamTrack, for name: String) {
        if let video = track as? RTCVideoTrack { update(name) { $0.video = video } }
    }

    fileprivate func stateChanged(_ state: RTCPeerConnectionState, for name: String) {
        update(name) { $0.trouble = state == .disconnected || state == .failed }
    }
}

/// Делегат одного соединения группового звонка.
final class GroupPeerDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    weak var owner: GroupCallService?
    let username: String

    init(owner: GroupCallService, username: String) {
        self.owner = owner
        self.username = username
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let name = username
        Task { @MainActor [weak self] in self?.owner?.didGenerate(candidate, for: name) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        let name = username
        Task { @MainActor [weak self] in self?.owner?.stateChanged(newState, for: name) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver,
                        streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track else { return }
        let name = username
        Task { @MainActor [weak self] in self?.owner?.didAddRemote(track, for: name) }
    }
}
