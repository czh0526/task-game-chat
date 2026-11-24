import SwiftUI

struct ConversationView: View {
    @Environment(AppModel.self) private var app
    var chatId: String

    @State private var draft = ""
    @State private var stickersOpen = false
    @State private var notice: String?
    @State private var sending = false

    private var showsThisChat: Bool { app.liveChatID == chatId }
    private var messages: [Message] { showsThisChat ? app.liveMessages : [] }
    private var chat: Chat? { showsThisChat ? app.liveChat : nil }
    private var loading: Bool { !showsThisChat || app.liveLoading }
    private var truncated: Bool { showsThisChat && app.liveTruncated }
    private var banner: String? {
        if let notice, !notice.isEmpty { return notice }
        guard showsThisChat, let live = app.liveNotice, !live.isEmpty else { return nil }
        return live
    }

    var body: some View {
        let tailID = messages.last?.id
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if loading && chat == nil && messages.isEmpty {
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
                .onChange(of: tailID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    Task { @MainActor in
                        proxy.scrollTo(id, anchor: .bottom)
                    }
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
                Button("刷新") { app.refreshLiveConversation() }
            }
        }
        .safeAreaInset(edge: .top) {
            if let banner {
                NoticeBanner(message: banner).padding(.horizontal)
            }
        }
        .onAppear { app.activateConversation(chatId) }
        .onDisappear { app.deactivateConversation(chatId) }
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
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !sending else { return }
        sending = true
        notice = nil
        let previousDraft = draft
        draft = ""
        stickersOpen = false
        defer { sending = false }
        if let error = await app.sendLiveMessage(chatId: chatId, type: type, text: body) {
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft = previousDraft.isEmpty ? body : previousDraft
            }
            notice = error
        }
    }
}
