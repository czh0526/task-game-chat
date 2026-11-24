import SwiftUI

struct InboxView: View {
    @Environment(AppModel.self) private var app
    @State private var path = NavigationPath()
    @State private var showOpen = false
    @State private var taskId = ""
    @State private var chatId = ""
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if app.inbox.isEmpty {
                    EmptyHint(
                        title: "还没有会话",
                        detail: "从好友里打开一对一聊天。任务会话要用任务编号打开；多人会话会在有人发消息、或你填了会话编号之后出现在这里。",
                        systemImage: "bubble.left.and.bubble.right"
                    )
                } else {
                    List(app.inbox) { chat in
                        Button {
                            path.append(ChatRoute(id: chat.id))
                        } label: {
                            inboxRow(chat)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .background(Theme.paper)
            .navigationTitle("消息")
            .navigationDestination(for: ChatRoute.self) { route in
                ConversationView(chatId: route.id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    StreamDot(phase: app.streamPhase)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("打开") { showOpen = true }
                }
            }
            .refreshable { await app.refreshInbox() }
            .overlay(alignment: .top) {
                if let status = app.statusBanner {
                    NoticeBanner(message: status)
                        .padding(.horizontal)
                        .onTapGesture { app.statusBanner = nil }
                }
            }
            .sheet(isPresented: $showOpen) {
                openSheet
            }
            .onAppear(perform: consumePendingChat)
            .onChange(of: app.pendingChatID) { _, _ in
                consumePendingChat()
            }
        }
    }

    private func inboxRow(_ chat: KnownChat) -> some View {
        HStack(spacing: 12) {
            UserAvatar(
                userId: chat.type == "direct" ? (chat.peerUserId ?? "") : (chat.memberIds.first ?? chat.id),
                name: app.title(for: chat),
                baseURL: app.baseURL,
                version: app.avatarVersion(for: chat.peerUserId ?? ""),
                size: 48
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(app.title(for: chat))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Spacer()
                    UnreadBadge(count: app.unreadCount(for: chat))
                }
                Text(subtitle(chat))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private func subtitle(_ chat: KnownChat) -> String {
        if let preview = chat.preview, !preview.isEmpty { return preview }
        var parts = [ChatKind.label(chat.type)]
        if let taskId = chat.taskId, !taskId.isEmpty { parts.append(taskId) }
        return parts.joined(separator: " · ")
    }

    private var openSheet: some View {
        NavigationStack {
            Form {
                NoticeBanner(message: notice)
                Section("任务会话") {
                    TextField("任务编号 tsk_…", text: $taskId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(busy ? "正在打开…" : "打开这个任务的会话") {
                        Task { await openTask() }
                    }
                    .disabled(busy || taskId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("已有的会话编号") {
                    TextField("会话编号 cht_…", text: $chatId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(busy ? "正在打开…" : "打开会话") {
                        Task { await openExisting() }
                    }
                    .disabled(busy || chatId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("接口不会列出你参加过的全部多人会话。知道编号，或等一条新消息，就能在这台手机上打开。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("打开会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showOpen = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func consumePendingChat() {
        guard let id = app.pendingChatID, !id.isEmpty else { return }
        app.pendingChatID = nil
        path.append(ChatRoute(id: id))
    }

    private func openTask() async {
        busy = true
        notice = nil
        defer { busy = false }
        do {
            let chats = try await app.openTaskChats(taskId: taskId)
            guard let first = chats.first else {
                notice = "这个任务还没有会话，或者你不是成员。"
                return
            }
            showOpen = false
            taskId = ""
            path.append(ChatRoute(id: first.id))
        } catch {
            app.expireIfNeeded(error)
            notice = APIErrorText.describe(error, baseURL: app.baseURL)
        }
    }

    private func openExisting() async {
        busy = true
        notice = nil
        defer { busy = false }
        do {
            let chat = try await app.openChat(id: chatId)
            showOpen = false
            chatId = ""
            path.append(ChatRoute(id: chat.id))
        } catch {
            app.expireIfNeeded(error)
            notice = APIErrorText.describe(error, baseURL: app.baseURL)
        }
    }
}
