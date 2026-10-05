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
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .chat(let id): ChatView(chatId: id)
        case .userProfile(let username): UserProfileView(username: username)
        case .groupInfo(let id): GroupInfoView(chatId: id)
        case .archive: ChatListView(archived: true)
        }
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
