import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if app.isRestoring {
                ZStack {
                    Theme.paper.ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在恢复登录…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if app.user == nil {
                AuthView()
            } else {
                TabView(selection: Binding(
                    get: { app.selectedTab },
                    set: { app.selectedTab = $0 }
                )) {
                    InboxView()
                        .badge(app.totalUnread)
                        .tabItem { Label("消息", systemImage: "bubble.left.and.bubble.right") }
                        .tag(0)
                    FriendsView()
                        .badge(app.incoming.count)
                        .tabItem { Label("好友", systemImage: "person.2") }
                        .tag(1)
                    ProfileView()
                        .tabItem { Label("我的", systemImage: "person.crop.circle") }
                        .tag(2)
                }
                .tint(Theme.persimmon)
            }
        }
        .task { await app.restore() }
        .onChange(of: scenePhase) { _, phase in
            app.sceneChanged(isActive: phase == .active)
        }
    }
}
