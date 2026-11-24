import SwiftUI

struct FriendsView: View {
    @Environment(AppModel.self) private var app
    @State private var path = NavigationPath()
    @State private var query = ""
    @State private var showAdd = false
    @State private var showRequests = false
    @State private var showGroup = false
    @State private var renaming: FriendGroupWithFriends?
    @State private var notice: String?
    @State private var busyUser: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let notice {
                    NoticeBanner(message: notice)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                if let friends = app.friends {
                    let sections = sections(from: friends)
                    if sections.allSatisfy(\.friends.isEmpty) && !query.isEmpty {
                        Text("没有匹配的好友。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sections, id: \.key) { section in
                        if !section.friends.isEmpty || query.isEmpty {
                            Section(section.title) {
                                if section.friends.isEmpty {
                                    Text("这个分组还没有人。")
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(section.friends) { friend in
                                    friendRow(friend, groupId: section.key)
                                }
                            }
                        }
                    }
                } else {
                    ProgressView("正在读取好友…")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.paper)
            .navigationTitle("好友")
            .searchable(text: $query, prompt: "昵称或用户编号")
            .refreshable { await app.refreshInbox() }
            .navigationDestination(for: ChatRoute.self) { route in
                ConversationView(chatId: route.id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(app.incoming.isEmpty ? "申请" : "申请 \(app.incoming.count)") {
                        showRequests = true
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("分组") { showGroup = true }
                    Button("添加") { showAdd = true }
                }
            }
            .sheet(isPresented: $showAdd) { AddFriendSheet() }
            .sheet(isPresented: $showRequests) { RequestsSheet() }
            .sheet(isPresented: $showGroup) { NewGroupSheet() }
            .sheet(item: $renaming) { group in
                RenameGroupSheet(group: group)
            }
        }
    }

    private struct SectionModel {
        var key: String
        var title: String
        var friends: [Friend]
    }

    private func sections(from list: FriendList) -> [SectionModel] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func keep(_ friend: Friend) -> Bool {
            needle.isEmpty
                || friend.nickname.lowercased().contains(needle)
                || friend.userId.lowercased().contains(needle)
        }
        var result = [SectionModel(key: "", title: "未分组", friends: list.ungrouped.filter(keep))]
        for group in list.groups {
            result.append(SectionModel(key: group.id, title: group.name, friends: group.friends.filter(keep)))
        }
        return result
    }

    private func friendRow(_ friend: Friend, groupId: String) -> some View {
        Button {
            Task { await open(friend) }
        } label: {
            HStack(spacing: 12) {
                UserAvatar(
                    userId: friend.userId,
                    name: app.label(for: friend.userId, nickname: friend.nickname),
                    baseURL: app.baseURL,
                    version: app.avatarVersion(for: friend.userId)
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.label(for: friend.userId, nickname: friend.nickname))
                        .foregroundStyle(Theme.ink)
                    Text(friend.userId)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if busyUser == friend.userId {
                    ProgressView()
                }
                UnreadBadge(count: max(0, friend.unreadCount))
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            moveMenu(friend: friend, current: groupId)
            Button("删除好友", role: .destructive) {
                Task {
                    notice = await app.unfriend(friend.userId)
                }
            }
            if !groupId.isEmpty, let group = app.friends?.groups.first(where: { $0.id == groupId }) {
                Button("重命名分组") { renaming = group }
                Button("删除分组", role: .destructive) {
                    Task { notice = await app.deleteGroup(group.id) }
                }
            }
        }
    }

    @ViewBuilder
    private func moveMenu(friend: Friend, current: String) -> some View {
        Menu("移动到分组") {
            if !current.isEmpty {
                Button("移出分组") {
                    Task { notice = await app.moveFriend(friend.userId, to: nil) }
                }
            }
            ForEach(app.friends?.groups ?? []) { group in
                if group.id != current {
                    Button(group.name) {
                        Task { notice = await app.moveFriend(friend.userId, to: group.id) }
                    }
                }
            }
        }
    }

    private func open(_ friend: Friend) async {
        busyUser = friend.userId
        defer { busyUser = nil }
        do {
            let chat = try await app.openDirectChat(with: friend.userId, nickname: friend.nickname)
            path.append(ChatRoute(id: chat.id))
        } catch {
            app.expireIfNeeded(error)
            notice = APIErrorText.describe(error, baseURL: app.baseURL)
        }
    }
}

private struct AddFriendSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var userId = ""
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                NoticeBanner(message: notice)
                TextField("对方的用户编号 usr_…", text: $userId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("如果对方已经向你发过申请，这一步会直接成为好友。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("添加好友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送") { Task { await send() } }
                        .disabled(busy || userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func send() async {
        busy = true
        let result = await app.sendFriendRequest(userId: userId)
        busy = false
        notice = result.message
        if result.ok { dismiss() }
    }
}

private struct RequestsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            List {
                if let notice { NoticeBanner(message: notice) }
                Section("收到的申请") {
                    if app.incoming.isEmpty {
                        Text("没有待处理的申请。").foregroundStyle(.secondary)
                    }
                    ForEach(app.incoming) { request in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(app.label(for: request.fromUserId, nickname: request.fromNickname))
                            Text(request.fromUserId).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("接受") { Task { notice = await app.acceptRequest(request.id) } }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Theme.ink)
                                Button("拒绝", role: .destructive) {
                                    Task { notice = await app.declineRequest(request.id) }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section("发出的申请") {
                    if app.outgoing.isEmpty {
                        Text("没有待对方确认的申请。").foregroundStyle(.secondary)
                    }
                    ForEach(app.outgoing) { request in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(app.label(for: request.toUserId, nickname: request.toNickname))
                                Text(request.toUserId).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("撤回") { Task { notice = await app.cancelRequest(request.id) } }
                        }
                    }
                }
            }
            .navigationTitle("好友申请")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

private struct NewGroupSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                NoticeBanner(message: notice)
                TextField("分组名称", text: $name)
                Text("分组只有你自己看得到。删掉分组不会解除好友。最多 50 个分组。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("新建分组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { Task { await create() } }
                        .disabled(busy)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func create() async {
        if let error = DisplayName.nicknameError(name) {
            notice = error.replacingOccurrences(of: "昵称", with: "分组名称")
            return
        }
        busy = true
        notice = await app.createGroup(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        busy = false
        if notice == nil { dismiss() }
    }
}

private struct RenameGroupSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var group: FriendGroupWithFriends
    @State private var name = ""
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                NoticeBanner(message: notice)
                TextField("分组名称", text: $name)
            }
            .navigationTitle("重命名分组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(busy)
                }
            }
            .onAppear { name = group.name }
        }
        .presentationDetents([.medium])
    }

    private func save() async {
        if let error = DisplayName.nicknameError(name) {
            notice = error.replacingOccurrences(of: "昵称", with: "分组名称")
            return
        }
        busy = true
        notice = await app.renameGroup(group.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        busy = false
        if notice == nil { dismiss() }
    }
}
