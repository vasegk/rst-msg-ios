import SwiftUI

/// Куда можно перейти внутри вкладки.
enum Route: Hashable {
    case chat(String)
    case userProfile(String)
    case groupInfo(String)
    case archive
}

struct MainTabView: View {
    enum Tab { case chats, settings }

    @Environment(AppModel.self) private var app
    @Environment(ChatListStore.self) private var store
    @Environment(Services.self) private var services
    @State private var tab: Tab = .chats
    @State private var chatsPath = NavigationPath()

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $chatsPath) {
                ChatListView(archived: false)
                    .navigationDestination(for: Route.self) { route in
                        destination(route)
                    }
            }
            .tabItem { Label("Чаты", systemImage: "bubble.left.and.bubble.right.fill") }
            .badge(store.totalUnread)
            .tag(Tab.chats)

            NavigationStack {
                SettingsView()
                    .navigationDestination(for: Route.self) { route in
                        destination(route)
                    }
            }
            .tabItem { Label("Настройки", systemImage: "gearshape.fill") }
            .tag(Tab.settings)
        }
        .onChange(of: app.pendingChat) { _, chatId in
            guard let chatId else { return }
            app.pendingChat = nil
            tab = .chats
            chatsPath = NavigationPath()
            chatsPath.append(Route.chat(chatId))
        }
        .alert("Не удалось вступить", isPresented: Binding(
            get: { app.joinError != nil }, set: { if !$0 { app.joinError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.joinError ?? "")
        }
        .alert(app.joinNotice ?? "", isPresented: Binding(
            get: { app.joinNotice != nil }, set: { if !$0 { app.joinNotice = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .sheet(item: Binding(get: { app.joinOffer }, set: { app.joinOffer = $0 })) { offer in
            JoinConfirmSheet(offer: offer)
                .presentationDetents([.medium])
        }
        .sheet(item: Binding(get: { app.stickerLink }, set: { app.stickerLink = $0 })) { StickerSetSheet(ref: $0) }
        .sheet(item: Binding(get: { app.qrApproval }, set: { app.qrApproval = $0 })) { QrApproveSheet(link: $0) }
        // Звонок: окно на весь экран; свёрнутый — плашка сверху
        .fullScreenCover(isPresented: Binding(
            get: { services.calls.phase != .idle && !services.calls.minimized },
            set: { if !$0 && services.calls.phase != .idle { services.calls.minimized = true } })) {
            CallView()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if services.calls.phase != .idle && services.calls.minimized { MinimizedCallBar() }
        }
        .alert(services.calls.notice ?? "", isPresented: Binding(
            get: { services.calls.notice != nil }, set: { if !$0 { services.calls.notice = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .chat(let id):
            // Группа с темами открывается списком тем
            if store.chat(id)?.isForum == true {
                TopicsListView(chatId: id)
            } else {
                ChatView(chatId: id)
            }
        case .userProfile(let username): UserProfileView(username: username)
        case .groupInfo(let id): GroupInfoView(chatId: id)
        case .archive: ChatListView(archived: true)
        }
    }
}

/// «Вступить?» перед входом по ссылке: аватар, название, число участников,
/// описание; при заявке — пометка. Вступление — только по нажатию.
struct JoinConfirmSheet: View {
    let offer: AppModel.JoinOffer
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private var preview: JoinPreviewResponse { offer.preview }

    var body: some View {
        VStack(spacing: 14) {
            AvatarView(name: preview.name ?? "Группа", url: preview.avatarUrl, size: 80)
            Text(preview.name ?? "Группа").font(.system(size: 20, weight: .bold))
            Text(countLine).font(.system(size: 14)).foregroundStyle(Theme.muted)
            if let description = preview.description, !description.isEmpty {
                Text(String(description.prefix(500)))
                    .font(.system(size: 14))
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
            }
            if preview.approval == true {
                Text("Вступление по заявке: её рассмотрят администраторы группы.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("Отмена") { dismiss() }
                    .buttonStyle(.bordered)
                Button(actionTitle) { app.confirmJoin(offer) }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 6)
        }
        .padding(24)
    }

    private var countLine: String {
        let n = preview.members ?? 0
        return preview.isChannel ? "Канал · \(n) подписч." : "Группа · \(n) \(Plural.members(n))"
    }

    private var actionTitle: String {
        if preview.approval == true { return "Подать заявку" }
        return preview.isChannel ? "Подписаться" : "Вступить"
    }
}

/// Полоса «нет связи» / «соединение…».
struct ConnectionBanner: View {
    @Environment(Services.self) private var services

    var body: some View {
        if !services.socket.state.connected {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Theme.muted)
                Text("Соединение…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Theme.surface.opacity(0.9))
        }
    }
}
