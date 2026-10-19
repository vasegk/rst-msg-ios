import SwiftUI
import WebRTC

/// Групповой звонок: сетка плиток по свободному месту, своя — первой.
struct GroupCallView: View {
    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    private var call: GroupCallService { services.groupCalls }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                header
                GeometryReader { geo in grid(geo.size) }
                    .padding(.horizontal, 8)
                controls
            }
        }
        .statusBarHidden()
    }

    private var header: some View {
        HStack {
            Button { call.minimized = true } label: {
                Image(systemName: "chevron.down").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(store.title(for: call.chatId ?? "")).font(.system(size: 16, weight: .semibold))
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(subtitle(ctx.date)).font(.system(size: 13)).opacity(0.75)
                }
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal)
    }

    private func subtitle(_ now: Date) -> String {
        let n = call.peers.count + 1
        var line = "\(n) " + Plural.members(n)
        if let start = call.startedAt {
            let s = Int(now.timeIntervalSince(start))
            line += String(format: " · %d:%02d", s / 60, s % 60)
        }
        return line
    }

    private func grid(_ size: CGSize) -> some View {
        let count = call.peers.count + 1
        let columns = count <= 1 ? 1 : (count <= 4 ? 2 : 3)
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        let height = max(120, (size.height - CGFloat(rows - 1) * 8) / CGFloat(rows))
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            tile(name: "Вы", username: services.me, video: call.cameraOn ? call.localVideo : nil, mic: !call.muted, trouble: false)
                .frame(height: height)
            ForEach(call.peers) { p in
                tile(name: store.displayName(p.username), username: p.username,
                     video: (p.camera || p.screen) ? p.video : nil, mic: p.mic, trouble: p.trouble)
                    .frame(height: height)
            }
        }
    }

    private func tile(name: String, username: String, video: RTCVideoTrack?, mic: Bool, trouble: Bool) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08))
            if let video {
                RTCVideoView(track: video).clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                AvatarView(name: name, url: store.users[username]?.avatarUrl, size: 72)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 4) {
                if !mic { Image(systemName: "mic.slash.fill").foregroundStyle(Theme.danger) }
                Text(name).lineLimit(1)
                if trouble { Image(systemName: "wifi.exclamationmark").foregroundStyle(.yellow) }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.5)))
            .padding(8)
        }
    }

    private var controls: some View {
        HStack(spacing: 22) {
            control(call.muted ? "mic.slash.fill" : "mic.fill", on: call.muted, label: "Микрофон") { call.toggleMute() }
            control(call.speaker ? "speaker.wave.3.fill" : "speaker.fill", on: call.speaker, label: "Динамик") { call.toggleSpeaker() }
            control(call.cameraOn ? "video.fill" : "video.slash.fill", on: call.cameraOn, label: "Камера") { call.toggleCamera() }
            Button { call.leave() } label: {
                VStack(spacing: 6) {
                    Image(systemName: "phone.down.fill").font(.system(size: 24)).foregroundStyle(.white)
                        .frame(width: 64, height: 64).background(Circle().fill(Theme.danger))
                    Text("Выйти").font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 30)
    }

    private func control(_ icon: String, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 22)).foregroundStyle(on ? .black : .white)
                    .frame(width: 60, height: 60).background(Circle().fill(on ? Color.white : Color.white.opacity(0.2)))
                Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .buttonStyle(.plain)
    }
}

/// Плашка в переписке группы: «Идёт звонок · N · Присоединиться».
struct GroupCallBanner: View {
    let chatId: String
    @Environment(Services.self) private var services

    var body: some View {
        let people = services.groupCalls.participants(in: chatId)
        if !people.isEmpty && services.groupCalls.chatId != chatId {
            HStack {
                Image(systemName: "phone.fill").foregroundStyle(Theme.success)
                Text("Идёт звонок · \(people.count) " + Plural.members(people.count)).font(.system(size: 14))
                Spacer()
                Button("Присоединиться") { services.groupCalls.join(chatId) }
                    .font(.system(size: 14, weight: .semibold))
                    .disabled(services.groupCalls.isActive || services.calls.isBusy)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.surface.opacity(0.95))
        }
    }
}

/// Свёрнутый групповой звонок — плашка сверху.
struct MinimizedGroupCallBar: View {
    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store

    var body: some View {
        let call = services.groupCalls
        HStack(spacing: 10) {
            Image(systemName: "person.3.fill")
            Text("\(store.title(for: call.chatId ?? "")) · \(call.peers.count + 1)").lineLimit(1)
            Spacer()
            Button("Вернуться") { call.minimized = false }.fontWeight(.semibold)
            Button { call.leave() } label: { Image(systemName: "phone.down.fill") }
        }
        .font(.system(size: 14))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.success.opacity(0.9))
        .contentShape(Rectangle())
        .onTapGesture { call.minimized = false }
    }
}

/// Групповой звонок поверх приложения.
struct GroupCallPresentation: ViewModifier {
    let calls: GroupCallService

    private var fullScreen: Binding<Bool> {
        Binding(get: { calls.isActive && !calls.minimized },
                set: { if !$0 && calls.isActive { calls.minimized = true } })
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { calls.notice != nil }, set: { if !$0 { calls.notice = nil } })
    }

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: fullScreen) { GroupCallView() }
            .safeAreaInset(edge: .top, spacing: 0) {
                if calls.isActive && calls.minimized { MinimizedGroupCallBar() }
            }
            .alert(calls.notice ?? "", isPresented: noticeShown) {
                Button("OK", role: .cancel) {}
            }
    }
}
