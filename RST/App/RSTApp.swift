import SwiftUI

@main
struct RSTApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(app.services)
                .environment(app.services.chats)
                .preferredColorScheme(app.colorScheme)
                .tint(Theme.accent)
                .onOpenURL { app.open(url: $0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { app.open(url: url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            app.scenePhaseChanged(phase)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            AppBackground()
            switch app.phase {
            case .launching:
                ProgressView().tint(Theme.accent)
            case .loggedOut:
                AuthFlowView()
                    .transition(.opacity)
            case .loggedIn:
                MainTabView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: app.phase)
        .task { if app.phase == .launching { app.start() } }
    }
}
