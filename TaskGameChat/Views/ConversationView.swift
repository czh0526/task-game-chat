import SwiftUI

struct ConversationView: View {
    @Environment(AppModel.self) private var app
    var chatId: String

    @State private var chat: Chat?
    @State private var messages: [Message] = []
    @State private var truncated = false
    @State private var draft = ""
    @State private var stickersOpen = false
    @State private var notice: String?
    @State private var loading = true
    @State private var sending = false
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if loading && chat == nil {
                            ProgressView("正在读取会话…")
                                .frame(maxWidth: .infinity)
                                .padding(.top, 32)
                        }
                        if messages.isEmpty && !loading {
                            Text("还没有消息。写一句发给对方。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 32)
                        }
                        ForEach(messages) { message in
                            bubble(message)
                                .id(message.id)
                        }
                        if truncated {
                            Text("消息较多，这里只显示读到的前 2000 条。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: messages.last?.id) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            composer
        }
        .background(Theme.paper)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(title).font(.headline)
                    if let chat {
                        Text(ChatKind.label(chat.type))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新") { schedule(markRead: app.sceneIsActive) }
            }
        }
        .safeAreaInset(edge: .top) {
            if let notice {
                NoticeBanner(message: notice).padding(.horizontal)
            }
        }
        .onAppear { app.openChatID = chatId }
        .task {
            app.openChatID = chatId
            await reload(markRead: true)
        }
        .onDisappear {
            if app.openChatID == chatId { app.openChatID = nil }
            loadTask?.cancel()
        }
        .onChange(of: app.eventGeneration) { _, _ in
            guard let signal = app.lastSignal else { return }
            if signal.type == "resync" || signal.type == "hello" || signal.chatId == chatId || signal.chatId == nil {
                schedule(markRead: app.sceneIsActive)
            }
        }
        .onChange(of: app.refreshGeneration) { _, _ in
            schedule(markRead: app.sceneIsActive)
        }
    }

    private var title: String {
        guard let chat else { return "会话" }
        if chat.type == "direct" {
            let peer = chat.memberIds.first { $0 != app.user?.id } ?? ""
            return "与 \(app.label(for: peer)) 的会话"
        }
        if chat.type == "task" { return "任务会话" }
        return "多人会话"
    }

    private func bubble(_ message: Message) -> some View {
        let mine = message.senderId == app.user?.id
        return HStack(alignment: .bottom, spacing: 8) {
            if mine { Spacer(minLength: 36) }
            if !mine {
                UserAvatar(
                    userId: message.senderId,
                    name: app.label(for: message.senderId),
                    baseURL: app.baseURL,
                    version: app.avatarVersion(for: message.senderId),
                    size: 32
                )
            }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                Text(app.label(for: message.senderId))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if message.type == "sticker" {
                    Text(message.text)
                        .font(.system(size: 48))
                        .accessibilityLabel(Stickers.label(for: message.text))
                } else {
                    Text(message.text.isEmpty ? message.attachmentRef : message.text)
                        .foregroundStyle(mine ? Color.white : Theme.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(mine ? Theme.ink : Theme.card, in: RoundedRectangle(cornerRadius: 16))
                }
                Text(ChatTime.format(message.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if !mine { Spacer(minLength: 36) }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if stickersOpen {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                    ForEach(Stickers.all) { sticker in
                        Button {
                            useSticker(sticker)
                        } label: {
                            VStack(spacing: 2) {
                                Text(sticker.char).font(.title2)
                                Text(sticker.label).font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("表情 \(sticker.label)")
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    stickersOpen.toggle()
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("表情")
                TextField("写一条消息", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(10)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                Button(action: sendDraft) {
                    if sending {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                }
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("发送")
            }
        }
        .padding(12)
        .background(.bar)
    }

    private func useSticker(_ sticker: EmojiSticker) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Task { await send(text: sticker.char, type: "sticker") }
            return
        }
        draft += sticker.char
    }

    private func sendDraft() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        if body.utf8.count > 8000 {
            notice = "消息最长 8000 字节。"
            return
        }
        if let sticker = Stickers.stickerChar(body) {
            Task { await send(text: sticker, type: "sticker") }
        } else {
            Task { await send(text: body, type: "text") }
        }
    }

    private func send(text: String, type: String) async {
        sending = true
        notice = nil
        defer { sending = false }
        do {
            let message = try await app.client().postMessage(chatId: chatId, type: type, text: text)
            if !messages.contains(where: { $0.id == message.id }) {
                messages.append(message)
            }
            draft = ""
            stickersOpen = false
            app.notePreview(chatId: chatId, text: type == "sticker" ? Stickers.label(for: text) : text)
        } catch {
            app.expireIfNeeded(error)
            notice = APIErrorText.describe(error, baseURL: app.baseURL)
        }
    }

    private func schedule(markRead: Bool) {
        loadTask?.cancel()
        loadTask = Task { await reload(markRead: markRead) }
    }

    private func reload(markRead: Bool) async {
        guard let client = try? app.client() else { return }
        do {
            let meta = try await client.getChat(id: chatId)
            let history = try await client.messageHistory(chatId: chatId)
            if Task.isCancelled { return }
            chat = meta
            messages = history.messages
            truncated = history.truncated
            loading = false
            await app.hydrateNicknames(meta.memberIds + history.messages.map(\.senderId))
            if let last = history.messages.last {
                let preview = last.type == "sticker" ? Stickers.label(for: last.text) : (last.text.isEmpty ? last.attachmentRef : last.text)
                app.notePreview(chatId: chatId, text: preview)
            }
            guard markRead, app.sceneIsActive else { return }
            let through = history.messages.last?.id
            _ = try await client.markRead(chatId: chatId, messageId: through)
            if Task.isCancelled { return }
            app.noteRead(chatId: chatId)
        } catch {
            if APIErrorText.isCancellation(error) || Task.isCancelled { return }
            loading = false
            app.expireIfNeeded(error)
            notice = APIErrorText.describe(error, baseURL: app.baseURL)
        }
    }
}
