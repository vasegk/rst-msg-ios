import SwiftUI
import WebRTC

/// Картинка дорожки WebRTC.
struct RTCVideoView: UIViewRepresentable {
    let track: RTCVideoTrack?
    var fill = true

    final class Coordinator {
        var track: RTCVideoTrack?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = fill ? .scaleAspectFill : .scaleAspectFit
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        guard context.coordinator.track !== track else { return }
        context.coordinator.track?.remove(view)
        track?.add(view)
        context.coordinator.track = track
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(view)
    }
}

/// Окно звонка: карточка собеседника или его видео, своё — в углу.
struct CallView: View {
    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    private var call: CallService { services.calls }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if call.remoteCamera || call.remoteScreen, call.remoteVideo != nil {
                RTCVideoView(track: call.remoteVideo, fill: !call.remoteScreen).ignoresSafeArea()
            } else {
                VStack(spacing: 14) {
                    AvatarView(name: store.displayName(call.peer),
                               url: store.users[call.peer]?.avatarUrl ?? store.chat(call.peer)?.avatarUrl, size: 120)
                    Text(store.displayName(call.peer)).font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                    statusLine
                }
            }
            VStack {
                HStack {
                    Button { call.minimized = true } label: {
                        Image(systemName: "chevron.down").font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white).frame(width: 44, height: 44)
                    }
                    Spacer()
                    if call.remoteCamera && call.phase == .active {
                        VStack(alignment: .trailing) {
                            Text(store.displayName(call.peer)).font(.system(size: 15, weight: .semibold))
                            statusLine
                        }
                        .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal)
                Spacer()
                controls
            }
            if call.cameraOn, call.localVideo != nil {
                VStack {
                    HStack {
                        Spacer()
                        RTCVideoView(track: call.localVideo)
                            .frame(width: 110, height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.4)))
                            .padding(.top, 70)
                            .padding(.trailing, 16)
                    }
                    Spacer()
                }
            }
        }
        .statusBarHidden()
    }

    private var statusLine: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(statusText(ctx.date)).font(.system(size: 15)).foregroundStyle(.white.opacity(0.8))
        }
    }

    private func statusText(_ now: Date) -> String {
        if !call.statusText.isEmpty { return call.statusText }
        guard let start = call.connectedAt else { return "" }
        let s = Int(now.timeIntervalSince(start))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    @ViewBuilder
    private var controls: some View {
        if call.phase == .incoming {
            HStack(spacing: 70) {
                round("phone.down.fill", color: Theme.danger, label: "Отклонить") { call.decline() }
                round(call.remoteCamera ? "video.fill" : "phone.fill", color: Theme.success, label: "Ответить") { call.answer() }
            }
            .padding(.bottom, 50)
        } else {
            VStack(spacing: 22) {
                HStack(spacing: 22) {
                    round(call.muted ? "mic.slash.fill" : "mic.fill", color: call.muted ? .white : .white.opacity(0.2),
                          fg: call.muted ? .black : .white, label: "Микрофон") { call.toggleMute() }
                    round(call.speaker ? "speaker.wave.3.fill" : "speaker.fill", color: call.speaker ? .white : .white.opacity(0.2),
                          fg: call.speaker ? .black : .white, label: "Динамик") { call.toggleSpeaker() }
                    round(call.cameraOn ? "video.fill" : "video.slash.fill", color: call.cameraOn ? .white : .white.opacity(0.2),
                          fg: call.cameraOn ? .black : .white, label: "Камера") { call.toggleCamera() }
                    if call.cameraOn {
                        round("arrow.triangle.2.circlepath.camera.fill", color: .white.opacity(0.2), label: "Сменить") { call.switchCamera() }
                    }
                }
                round("phone.down.fill", color: Theme.danger, label: "Завершить") { call.hangup() }
            }
            .padding(.bottom, 40)
        }
    }

    private func round(_ icon: String, color: Color, fg: Color = .white, label: String,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 24)).foregroundStyle(fg)
                    .frame(width: 64, height: 64).background(Circle().fill(color))
                Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .buttonStyle(.plain)
    }
}

/// Плашка свёрнутого звонка: «Имя · время · Вернуться / Завершить».
struct MinimizedCallBar: View {
    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    private var call: CallService { services.calls }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: call.cameraOn ? "video.fill" : "phone.fill")
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(store.displayName(call.peer) + " · " + time(ctx.date)).lineLimit(1)
            }
            Spacer()
            Button("Вернуться") { call.minimized = false }.fontWeight(.semibold)
            Button { call.hangup() } label: { Image(systemName: "phone.down.fill") }
        }
        .font(.system(size: 14))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.success.opacity(0.9))
        .contentShape(Rectangle())
        .onTapGesture { call.minimized = false }
    }

    private func time(_ now: Date) -> String {
        guard let start = call.connectedAt else { return call.statusText }
        let s = Int(now.timeIntervalSince(start))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Журнал звонков: свои и входящие.
struct CallHistoryView: View {
    @Environment(Services.self) private var services
    @State private var calls: [CallHistoryItem]?
    @State private var error: String?

    var body: some View {
        List {
            if let calls {
                if calls.isEmpty { Text("Звонков пока не было").foregroundStyle(Theme.muted) }
                ForEach(calls) { c in
                    HStack(spacing: 12) {
                        AvatarView(name: c.peerName ?? c.peer, url: c.avatarUrl, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.peerName ?? c.peer)
                                .foregroundStyle(c.status == "missed" && c.outgoing != true ? Theme.danger : Theme.onSurface)
                            HStack(spacing: 4) {
                                Image(systemName: c.outgoing == true ? "arrow.up.right" : "arrow.down.left").font(.system(size: 11))
                                Text(Self.caption(c)).font(.system(size: 12))
                            }
                            .foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Button { services.calls.call(c.peer, video: c.video == true) } label: {
                            Image(systemName: c.video == true ? "video" : "phone").foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .disabled(services.calls.isBusy)
                    }
                }
            } else if let error {
                Text(error).foregroundStyle(Theme.danger)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Звонки")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { calls = try await services.api.callHistory().calls ?? [] } catch { self.error = errorText(error) }
        }
    }

    static func caption(_ c: CallHistoryItem) -> String {
        var parts: [String] = []
        switch c.status {
        case "answered":
            let d = c.duration ?? 0
            parts.append(String(format: "%d:%02d", d / 60, d % 60))
        case "missed": parts.append(c.outgoing == true ? "не ответили" : "пропущенный")
        case "declined": parts.append("отклонён")
        case "busy": parts.append("занято")
        default: parts.append("не удалось")
        }
        parts.append(TimeFormat.listTime(ServerTime.parse(c.time)))
        return parts.joined(separator: " · ")
    }
}
