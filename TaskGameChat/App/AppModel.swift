import Foundation
import Observation
import UserNotifications

struct KnownChat: Codable, Identifiable, Hashable {
    var id: String
    var type: String
    var taskId: String?
    var memberIds: [String]
    var peerUserId: String?
    var preview: String?
    var updatedAt: Date
    var serverUnread: Int
    var localUnread: Int
}

struct ChatRoute: Hashable, Identifiable {
    var id: String
}

@MainActor
@Observable
final class AppModel {
    var baseURL: String
    var user: UserSummary?
    var isRestoring = true
    var authBanner: String?
    var friends: FriendList?
    var incoming: [FriendRequest] = []
    var outgoing: [FriendRequest] = []
    var knownChats: [KnownChat] = []
    var nicknames: [String: String] = [:]
    var avatarVersions: [String: Int] = [:]
    var streamPhase: StreamPhase = .idle
    var statusBanner: String?
    var openChatID: String?
    /// Transcript of the conversation the panel is showing. The view reads this directly.
    var liveChatID: String?
    var liveMessages: [Message] = []
    var liveChat: Chat?
    var liveTruncated = false
    var liveLoading = false
    var liveNotice: String?
    var pendingChatID: String?
    var selectedTab = 0
    var sceneIsActive = true
    var notificationsEnabled: Bool
    var eventGeneration = 0
    var refreshGeneration = 0
    var lastSignal: StreamSignal?

    private var token: String?
    private var didRestore = false
    private var streamBound = false
    private var seenMessageIDs: [String] = []
    private var pollTask: Task<Void, Never>?
    private var liveTailCursor: String?
    private var liveHistoryReady = false
    private var liveTailFollowUp = false
    private var liveGeneration = 0
    private var liveTask: Task<Void, Never>?
    private let stream = EventStream()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let baseURL = "taskgame.chat.baseURL"
        static let notify = "taskgame.chat.notify"
        static func chats(_ userId: String) -> String { "taskgame.chat.known.\(userId)" }
    }

    var hasStoredSession: Bool { token?.isEmpty == false }

    init() {
        let stored = UserDefaults.standard.string(forKey: Keys.baseURL)?.trimmingCharacters(in: .whitespacesAndNewlines)
        baseURL = (stored?.isEmpty == false) ? stored! : ServiceURLs.defaultBase
        notificationsEnabled = UserDefaults.standard.bool(forKey: Keys.notify)
    }

    func restore() async {
        guard !didRestore else { return }
        didRestore = true
        token = KeychainStore.loadToken()
        guard hasStoredSession else {
            isRestoring = false
            return
        }
        await resumeSession()
    }

    func retrySession() async {
        guard hasStoredSession else { return }
        await resumeSession()
    }

    func login(email: String, password: String) async -> String? {
        await authenticate { try await $0.login(email: email, password: password) }
    }

    func register(email: String, password: String, nickname: String?) async -> String? {
        await authenticate { try await $0.register(email: email, password: password, nickname: nickname) }
    }

    func logout() {
        stream.stop(resetCursor: true)
        pollTask?.cancel()
        pollTask = nil
        KeychainStore.deleteToken()
        token = nil
        user = nil
        friends = nil
        incoming = []
        outgoing = []
        knownChats = []
        nicknames = [:]
        openChatID = nil
        clearLiveTranscript()
        pendingChatID = nil
        streamPhase = .idle
        statusBanner = nil
    }

    func updateBaseURL(_ raw: String) -> String? {
        do {
            _ = try ServiceURLs.resolve(raw)
        } catch {
            return APIErrorText.describe(error, baseURL: raw)
        }
        baseURL = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(baseURL, forKey: Keys.baseURL)
        if user != nil { startStream() }
        return nil
    }

    func ping() async -> String {
        do {
            let status = try await APIClient(baseURL: baseURL, token: nil).health()
            if status.status == "ok" { return "已连上 \(baseURL)" }
            return "服务返回 \(status.status)"
        } catch {
            let text = APIErrorText.describe(error, baseURL: baseURL)
            return text.isEmpty ? "没有连上。" : text
        }
    }

    func sceneChanged(isActive: Bool) {
        let was = sceneIsActive
        sceneIsActive = isActive
        guard isActive, !was, user != nil else { return }
        Task { await foregroundRefresh() }
    }

    func client() throws -> APIClient {
        try APIClient(baseURL: baseURL, token: token)
    }

    func expireIfNeeded(_ error: Error) {
        guard APIErrorText.isUnauthorized(error) else { return }
        logout()
        authBanner = "登录已失效，请重新登录。"
    }

    var totalUnread: Int {
        let direct: Int
        if let friends {
            direct = friends.everyone.reduce(0) { $0 + max(0, $1.unreadCount) }
        } else {
            direct = knownChats.filter { $0.type == "direct" }.reduce(0) { $0 + max(0, $1.serverUnread) }
        }
        let other = knownChats.filter { $0.type != "direct" }.reduce(0) { $0 + max(0, $1.localUnread) }
        return direct + other
    }

    var inbox: [KnownChat] {
        knownChats.sorted { lhs, rhs in
            let leftUnread = unreadCount(for: lhs) > 0
            let rightUnread = unreadCount(for: rhs) > 0
            if leftUnread != rightUnread { return leftUnread }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func unreadCount(for chat: KnownChat) -> Int {
        if chat.type == "direct" {
            if let friends, let friend = friends.everyone.first(where: { $0.directChatId == chat.id }) {
                return max(0, friend.unreadCount)
            }
            return max(0, chat.serverUnread)
        }
        return max(0, chat.localUnread)
    }

    func title(for chat: KnownChat) -> String {
        switch chat.type {
        case "direct":
            let peer = chat.peerUserId ?? ""
            return DisplayName.personLabel(nickname: nicknames[peer], userId: peer)
        case "task":
            if let taskId = chat.taskId, !taskId.isEmpty {
                return "任务 …\(DisplayName.idSuffix(taskId))"
            }
            return "任务会话"
        default:
            let names = chat.memberIds
                .filter { $0 != user?.id }
                .map { DisplayName.personLabel(nickname: nicknames[$0], userId: $0) }
            return names.isEmpty ? "多人会话" : names.joined(separator: "、")
        }
    }

    func label(for userId: String, nickname: String? = nil) -> String {
        let known = nickname ?? nicknames[userId]
        return DisplayName.personLabel(nickname: known, userId: userId)
    }

    func refreshInbox() async {
        await refreshSocial()
        guard let client = try? client() else { return }
        let others = knownChats.filter { $0.type != "direct" }.prefix(20)
        for chat in others {
            if let fresh = try? await client.getChat(id: chat.id) {
                remember(fresh, touchDate: false)
            }
        }
        refreshGeneration &+= 1
    }

    func openDirectChat(with userId: String, nickname: String?) async throws -> Chat {
        let chat = try await client().openDirectChat(userId: userId)
        if let nickname { nicknames[userId] = nickname }
        remember(chat)
        return chat
    }

    func openTaskChats(taskId: String) async throws -> [Chat] {
        let list = try await client().listTaskChats(taskId: taskId.trimmingCharacters(in: .whitespacesAndNewlines))
        for chat in list.items { remember(chat) }
        return list.items
    }

    func openChat(id: String) async throws -> Chat {
        let chat = try await client().getChat(id: id.trimmingCharacters(in: .whitespacesAndNewlines))
        remember(chat)
        await hydrateNicknames(chat.memberIds)
        return chat
    }

    func notePreview(chatId: String, text: String) {
        guard let index = knownChats.firstIndex(where: { $0.id == chatId }) else { return }
        knownChats[index].preview = text
        knownChats[index].updatedAt = Date()
        saveChats()
    }

    func noteRead(chatId: String) {
        guard let index = knownChats.firstIndex(where: { $0.id == chatId }) else { return }
        knownChats[index].localUnread = 0
        if knownChats[index].type == "direct" {
            knownChats[index].serverUnread = 0
        }
        saveChats()
        Task { await refreshSocial() }
    }

    func sendFriendRequest(userId: String) async -> (ok: Bool, message: String) {
        do {
            let request = try await client().createFriendRequest(userId: userId.trimmingCharacters(in: .whitespacesAndNewlines))
            await refreshSocial()
            if request.status == "accepted" {
                return (true, "对方已经向你发过申请，现在是好友了。")
            }
            return (true, "申请已发出。")
        } catch {
            expireIfNeeded(error)
            let text = APIErrorText.describe(error, baseURL: baseURL)
            return (false, text.isEmpty ? "申请失败。" : text)
        }
    }

    func acceptRequest(_ id: String) async -> String? {
        await mutate { _ = try await $0.acceptFriendRequest(id: id); return nil }
    }

    func declineRequest(_ id: String) async -> String? {
        await mutate { _ = try await $0.declineFriendRequest(id: id); return nil }
    }

    func cancelRequest(_ id: String) async -> String? {
        await mutate { _ = try await $0.cancelFriendRequest(id: id); return nil }
    }

    func unfriend(_ userId: String) async -> String? {
        await mutate { _ = try await $0.unfriend(userId: userId); return nil }
    }

    func moveFriend(_ userId: String, to groupId: String?) async -> String? {
        await mutate { _ = try await $0.setFriendGroup(userId: userId, groupId: groupId); return nil }
    }

    func createGroup(name: String) async -> String? {
        await mutate { _ = try await $0.createFriendGroup(name: name); return nil }
    }

    func renameGroup(_ id: String, name: String) async -> String? {
        await mutate { _ = try await $0.renameFriendGroup(id: id, name: name); return nil }
    }

    func deleteGroup(_ id: String) async -> String? {
        await mutate { _ = try await $0.deleteFriendGroup(id: id); return nil }
    }

    func saveNickname(_ raw: String) async -> String? {
        if let error = DisplayName.nicknameError(raw) { return error }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let updated = try await client().updateMe(nickname: name)
            user = updated
            nicknames[updated.id] = updated.nickname
            return nil
        } catch {
            expireIfNeeded(error)
            let text = APIErrorText.describe(error, baseURL: baseURL)
            return text.isEmpty ? nil : text
        }
    }

    func uploadAvatar(dataURL: String) async -> String? {
        do {
            let summary = try await client().putAvatar(image: dataURL)
            avatarVersions[summary.userId] = Int(Date().timeIntervalSince1970)
            return nil
        } catch {
            expireIfNeeded(error)
            let text = APIErrorText.describe(error, baseURL: baseURL)
            return text.isEmpty ? nil : text
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) async -> String? {
        if !enabled {
            notificationsEnabled = false
            defaults.set(false, forKey: Keys.notify)
            return "已关闭新消息通知。"
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        var status = settings.authorizationStatus
        if status == .notDetermined {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            status = granted ? .authorized : .denied
        }
        guard status == .authorized || status == .provisional || status == .ephemeral else {
            notificationsEnabled = false
            defaults.set(false, forKey: Keys.notify)
            return "系统没有允许通知。请到「设置 › 任务会话」里打开。"
        }
        notificationsEnabled = true
        defaults.set(true, forKey: Keys.notify)
        return "已开启。别人发来消息、而你不在那个会话里时会提醒。"
    }

    func openFromNotification(_ chatId: String) {
        selectedTab = 0
        pendingChatID = chatId
    }

    func shouldSuppressNotification(chatId: String?) -> Bool {
        guard let chatId, sceneIsActive, openChatID == chatId else { return false }
        return true
    }

    func avatarVersion(for userId: String) -> Int {
        avatarVersions[userId] ?? 0
    }

    private func resumeSession() async {
        isRestoring = true
        defer { isRestoring = false }
        do {
            let profile = try await client().me()
            user = profile
            nicknames[profile.id] = profile.nickname
            loadChats()
            await afterSignIn()
            authBanner = nil
        } catch {
            if APIErrorText.isUnauthorized(error) {
                KeychainStore.deleteToken()
                token = nil
                user = nil
                authBanner = "登录已失效，请重新登录。"
            } else if !APIErrorText.isCancellation(error) {
                user = nil
                authBanner = APIErrorText.describe(error, baseURL: baseURL)
            }
        }
    }

    private func authenticate(_ call: (APIClient) async throws -> AuthSession) async -> String? {
        do {
            let session = try await call(APIClient(baseURL: baseURL, token: nil))
            try KeychainStore.saveToken(session.accessToken)
            token = session.accessToken
            user = session.user
            nicknames[session.user.id] = session.user.nickname
            loadChats()
            authBanner = nil
            await afterSignIn()
            return nil
        } catch let error as KeychainError {
            return "登录成功，但钥匙串没有写下令牌（\(error.status)）。"
        } catch {
            let text = APIErrorText.describe(error, baseURL: baseURL)
            return text.isEmpty ? "登录失败。" : text
        }
    }

    private func afterSignIn() async {
        startStream()
        startPoll()
        await refreshSocial()
    }

    private func foregroundRefresh() async {
        startStream()
        await refreshSocial()
        refreshGeneration &+= 1
    }

    private func fallbackRefresh() async {
        guard user != nil, sceneIsActive else { return }
        await refreshSocial()
        if liveChatID != nil {
            startLiveLoad(full: false)
        }
        refreshGeneration &+= 1
    }

    private func refreshSocial() async {
        guard let client = try? client() else { return }
        do {
            let list = try await client.listFriends()
            friends = list
            absorb(list)
            statusBanner = nil
        } catch {
            if APIErrorText.isUnauthorized(error) {
                expireIfNeeded(error)
                return
            }
            if friends == nil {
                friends = FriendList(groups: [], ungrouped: [])
            }
            if !APIErrorText.isCancellation(error) {
                statusBanner = APIErrorText.describe(error, baseURL: baseURL)
            }
        }
        async let incomingList = client.listFriendRequests(direction: "incoming")
        async let outgoingList = client.listFriendRequests(direction: "outgoing")
        if let incomingList = try? await incomingList { incoming = incomingList.items }
        if let outgoingList = try? await outgoingList { outgoing = outgoingList.items }
    }

    private func mutate(_ work: (APIClient) async throws -> String?) async -> String? {
        do {
            let note = try await work(client())
            await refreshSocial()
            return note
        } catch {
            expireIfNeeded(error)
            let text = APIErrorText.describe(error, baseURL: baseURL)
            return text.isEmpty ? nil : text
        }
    }

    private func startStream() {
        guard let token, !token.isEmpty else { return }
        if !streamBound {
            streamBound = true
            bindStream()
        }
        stream.start(baseURL: baseURL, token: token)
    }

    private func startPoll() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.fallbackRefresh()
            }
        }
    }

    private func bindStream() {
        stream.onPhase = { [weak self] phase in
            Task { @MainActor in
                self?.streamPhase = phase
            }
        }
        stream.onSignal = { [weak self] signal in
            Task { @MainActor in
                self?.handle(signal)
            }
        }
        stream.onUnauthorized = { [weak self] in
            Task { @MainActor in
                self?.logout()
                self?.authBanner = "登录已失效，请重新登录。"
            }
        }
    }

    private func handle(_ signal: StreamSignal) {
        lastSignal = signal
        eventGeneration &+= 1
        switch signal.type {
        case "chat.message":
            if signal.chatId == liveChatID, signal.chatId?.isEmpty == false {
                startLiveLoad(full: false)
            }
            Task { await handleIncoming(signal) }
        case "hello":
            if liveChatID != nil { startLiveLoad(full: true) }
            Task { await refreshSocial() }
        case "resync":
            if liveChatID != nil { startLiveLoad(full: true) }
            Task {
                await refreshSocial()
                refreshGeneration &+= 1
            }
        default:
            break
        }
    }

    func activateConversation(_ chatId: String) {
        openChatID = chatId
        guard liveChatID != chatId else {
            if liveHistoryReady { startLiveLoad(full: false) }
            return
        }
        liveTask?.cancel()
        liveChatID = chatId
        liveMessages = []
        liveChat = nil
        liveTruncated = false
        liveLoading = true
        liveNotice = nil
        liveTailCursor = nil
        liveHistoryReady = false
        liveTailFollowUp = false
        startLiveLoad(full: true)
    }

    func deactivateConversation(_ chatId: String) {
        if openChatID == chatId { openChatID = nil }
    }

    func refreshLiveConversation() {
        guard liveChatID != nil else { return }
        startLiveLoad(full: true)
    }

    func sendLiveMessage(chatId: String, type: String, text: String) async -> String? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let localID = "\(MessageLog.localPrefix)\(UUID().uuidString)"
        if liveChatID == chatId {
            let pending = Message(
                id: localID,
                chatId: chatId,
                senderId: user?.id ?? "",
                type: type,
                text: body,
                attachmentRef: "",
                createdAt: ChatTime.stamp(Date())
            )
            liveMessages = MessageLog.upserting([pending], into: liveMessages)
        }
        let preview = type == "sticker" ? Stickers.label(for: body) : body
        let previousPreview = knownChats.first { $0.id == chatId }?.preview
        notePreview(chatId: chatId, text: preview)
        do {
            let message = try await client().postMessage(chatId: chatId, type: type, text: body)
            guard liveChatID == chatId else { return nil }
            liveMessages = MessageLog.replacing(localID: localID, with: message, in: liveMessages)
            notePreview(chatId: chatId, text: preview)
            return nil
        } catch {
            if liveChatID == chatId {
                liveMessages.removeAll { $0.id == localID }
                if liveMessages.isEmpty {
                    notePreview(chatId: chatId, text: previousPreview ?? "")
                } else {
                    noteLivePreview()
                }
            }
            expireIfNeeded(error)
            let text = APIErrorText.describe(error, baseURL: baseURL)
            return text.isEmpty ? "发送失败。" : text
        }
    }

    private func clearLiveTranscript() {
        liveTask?.cancel()
        liveTask = nil
        liveChatID = nil
        liveMessages = []
        liveChat = nil
        liveTruncated = false
        liveLoading = false
        liveNotice = nil
        liveTailCursor = nil
        liveHistoryReady = false
        liveTailFollowUp = false
    }

    private func startLiveLoad(full: Bool) {
        if !full, !liveHistoryReady {
            liveTailFollowUp = true
            return
        }
        liveGeneration &+= 1
        let generation = liveGeneration
        let markRead = sceneIsActive && openChatID != nil && openChatID == liveChatID
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            if full {
                await self?.reloadLive(generation: generation, markRead: markRead)
            } else {
                await self?.syncLiveTail(generation: generation, markRead: markRead)
            }
        }
    }

    private func isLiveCurrent(_ generation: Int) -> Bool {
        generation == liveGeneration && !Task.isCancelled && liveChatID != nil
    }

    private func reloadLive(generation: Int, markRead: Bool) async {
        guard let chatId = liveChatID, let client = try? client() else { return }
        do {
            let meta = try await client.getChat(id: chatId)
            let history = try await client.messageHistory(chatId: chatId)
            guard isLiveCurrent(generation), liveChatID == chatId else { return }
            liveChat = meta
            liveMessages = MessageLog.applying(snapshot: history.messages, keeping: liveMessages)
            liveTruncated = history.truncated
            liveTailCursor = history.tailCursor
            liveHistoryReady = true
            liveLoading = false
            liveNotice = nil
            await hydrateNicknames(meta.memberIds + liveMessages.map(\.senderId))
            guard isLiveCurrent(generation), liveChatID == chatId else { return }
            noteLivePreview()
            if markRead {
                try await acknowledgeLiveRead(client, chatId: chatId)
            }
            guard isLiveCurrent(generation), liveChatID == chatId else { return }
            if liveTailFollowUp {
                liveTailFollowUp = false
                startLiveLoad(full: false)
            }
        } catch {
            guard isLiveCurrent(generation), liveChatID == chatId, !APIErrorText.isCancellation(error) else { return }
            liveLoading = false
            expireIfNeeded(error)
            liveNotice = APIErrorText.describe(error, baseURL: baseURL)
        }
    }

    private func syncLiveTail(generation: Int, markRead: Bool) async {
        guard let chatId = liveChatID, let client = try? client() else { return }
        do {
            var cursor = liveTailCursor
            var pages = 0
            while pages < 20 {
                let list = try await client.listMessages(chatId: chatId, limit: 100, cursor: cursor)
                guard isLiveCurrent(generation), liveChatID == chatId else { return }
                liveMessages = MessageLog.upserting(list.items, into: liveMessages)
                let next = list.nextCursor
                liveTailCursor = MessageCursor.resume(requested: cursor, next: next)
                if let next, !next.isEmpty {
                    cursor = next
                    pages += 1
                    if pages == 20 {
                        liveTruncated = true
                        break
                    }
                    continue
                }
                liveTruncated = false
                break
            }
            guard isLiveCurrent(generation), liveChatID == chatId else { return }
            liveLoading = false
            liveNotice = nil
            await hydrateNicknames(liveMessages.map(\.senderId))
            guard isLiveCurrent(generation), liveChatID == chatId else { return }
            noteLivePreview()
            guard markRead else { return }
            try await acknowledgeLiveRead(client, chatId: chatId)
        } catch {
            guard isLiveCurrent(generation), liveChatID == chatId, !APIErrorText.isCancellation(error) else { return }
            liveLoading = false
            expireIfNeeded(error)
            liveNotice = APIErrorText.describe(error, baseURL: baseURL)
        }
    }

    private func acknowledgeLiveRead(_ client: APIClient, chatId: String) async throws {
        guard sceneIsActive, openChatID == chatId else { return }
        let through = liveMessages.last(where: { !MessageLog.isLocal($0.id) })?.id
        _ = try await client.markRead(chatId: chatId, messageId: through)
        guard !Task.isCancelled, liveChatID == chatId else { return }
        noteRead(chatId: chatId)
    }

    private func noteLivePreview() {
        guard let chatId = liveChatID, let last = liveMessages.last else { return }
        let preview = last.type == "sticker" ? Stickers.label(for: last.text) : (last.text.isEmpty ? last.attachmentRef : last.text)
        notePreview(chatId: chatId, text: preview)
    }

    private func handleIncoming(_ signal: StreamSignal) async {
        guard signal.type == "chat.message" else { return }
        await refreshSocial()
        guard let chatId = signal.chatId, !chatId.isEmpty else { return }
        if !knownChats.contains(where: { $0.id == chatId }), let client = try? client() {
            if let chat = try? await client.getChat(id: chatId) {
                remember(chat)
                await hydrateNicknames(chat.memberIds)
            }
        }
        if let sender = signal.senderId, nicknames[sender] == nil {
            await hydrateNicknames([sender])
        }
        let mine = signal.senderId == nil || signal.senderId == user?.id || signal.senderId?.isEmpty == true
        let viewing = sceneIsActive && openChatID == chatId
        guard !mine, !viewing else { return }
        if let index = knownChats.firstIndex(where: { $0.id == chatId }), knownChats[index].type != "direct" {
            knownChats[index].localUnread += 1
            knownChats[index].updatedAt = Date()
            saveChats()
        }
        await postNotification(signal)
    }

    private func postNotification(_ signal: StreamSignal) async {
        guard notificationsEnabled, let chatId = signal.chatId, !chatId.isEmpty else { return }
        let key = signal.messageId ?? "\(chatId):\(signal.senderId ?? "")"
        if seenMessageIDs.contains(key) { return }
        seenMessageIDs.append(key)
        if seenMessageIDs.count > 256 { seenMessageIDs.removeFirst(seenMessageIDs.count - 128) }
        let sender = signal.senderId ?? ""
        let name = label(for: sender)
        let content = UNMutableNotificationContent()
        content.title = name == "未命名" || sender.isEmpty ? "新消息" : "新消息 · \(name)"
        content.body = "点开查看"
        content.sound = .default
        content.userInfo = ["chat_id": chatId]
        content.threadIdentifier = chatId
        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func hydrateNicknames(_ ids: [String]) async {
        guard let client = try? client() else { return }
        let missing = Array(Set(ids.filter { !$0.isEmpty && nicknames[$0] == nil }))
        for id in missing.prefix(30) {
            if let scores = try? await client.userScores(userId: id) {
                nicknames[id] = scores.nickname
            } else {
                nicknames[id] = ""
            }
        }
    }

    private func absorb(_ list: FriendList) {
        var seenDirect = Set<String>()
        for friend in list.everyone {
            nicknames[friend.userId] = friend.nickname
            guard let chatId = friend.directChatId, !chatId.isEmpty else { continue }
            seenDirect.insert(chatId)
            var item = knownChats.first(where: { $0.id == chatId }) ?? KnownChat(
                id: chatId,
                type: "direct",
                taskId: nil,
                memberIds: [user?.id, friend.userId].compactMap { $0 },
                peerUserId: friend.userId,
                preview: nil,
                updatedAt: Date(),
                serverUnread: friend.unreadCount,
                localUnread: 0
            )
            item.type = "direct"
            item.peerUserId = friend.userId
            if let me = user?.id, !item.memberIds.contains(friend.userId) {
                item.memberIds = [me, friend.userId]
            }
            item.serverUnread = friend.unreadCount
            upsert(item, save: false)
        }
        for index in knownChats.indices where knownChats[index].type == "direct" && !seenDirect.contains(knownChats[index].id) {
            knownChats[index].serverUnread = 0
        }
        saveChats()
    }

    private func remember(_ chat: Chat, touchDate: Bool = true) {
        var item = knownChats.first(where: { $0.id == chat.id }) ?? KnownChat(
            id: chat.id,
            type: chat.type,
            taskId: chat.taskId,
            memberIds: chat.memberIds,
            peerUserId: chat.memberIds.first { $0 != user?.id },
            preview: nil,
            updatedAt: Date(),
            serverUnread: 0,
            localUnread: 0
        )
        item.type = chat.type
        item.taskId = chat.taskId
        item.memberIds = chat.memberIds
        item.peerUserId = chat.memberIds.first { $0 != user?.id }
        if touchDate { item.updatedAt = Date() }
        upsert(item)
    }

    private func upsert(_ item: KnownChat, save: Bool = true) {
        if let index = knownChats.firstIndex(where: { $0.id == item.id }) {
            knownChats[index] = item
        } else {
            knownChats.append(item)
        }
        if save { saveChats() }
    }

    private func loadChats() {
        guard let user else {
            knownChats = []
            return
        }
        guard let data = defaults.data(forKey: Keys.chats(user.id)),
              let decoded = try? JSONDecoder().decode([KnownChat].self, from: data)
        else {
            knownChats = []
            return
        }
        knownChats = decoded
    }

    private func saveChats() {
        guard let user, let data = try? JSONEncoder().encode(knownChats) else { return }
        defaults.set(data, forKey: Keys.chats(user.id))
    }
}
