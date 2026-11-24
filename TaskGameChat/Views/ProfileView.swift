import PhotosUI
import SwiftUI
import UIKit

struct ProfileView: View {
    @Environment(AppModel.self) private var app
    @State private var nickname = ""
    @State private var server = ""
    @State private var notice: String?
    @State private var picker: PhotosPickerItem?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                if let user = app.user {
                    Section {
                        HStack(spacing: 16) {
                            PhotosPicker(selection: $picker, matching: .images) {
                                UserAvatar(
                                    userId: user.id,
                                    name: app.label(for: user.id, nickname: user.nickname),
                                    baseURL: app.baseURL,
                                    version: app.avatarVersion(for: user.id),
                                    size: 72
                                )
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(app.label(for: user.id, nickname: user.nickname))
                                    .font(.title3.weight(.semibold))
                                Text(user.email.isEmpty ? "没有邮箱" : user.email)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if user.isArbiter {
                                    Text("裁定者")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(Theme.mist, in: Capsule())
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        Button("复制用户编号") {
                            UIPasteboard.general.string = user.id
                            notice = "已复制 \(user.id)"
                        }
                        Text(user.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Section("昵称") {
                        TextField("显示名称", text: $nickname)
                        Button(busy ? "正在保存…" : "保存昵称") {
                            Task { await saveNickname() }
                        }
                        .disabled(busy)
                        Text("1 到 32 个字符。昵称可以和别人重复，登录仍然用邮箱。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("服务器") {
                    TextField("http://127.0.0.1:8891", text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("保存地址") {
                        notice = app.updateBaseURL(server) ?? "已保存服务器地址。"
                    }
                    Button("测试连接") {
                        Task { notice = await app.ping() }
                    }
                    StreamDot(phase: app.streamPhase)
                    Text("实时通道大约每 15 秒有一次心跳。断线会带上 Last-Event-ID 重连，服务器会要求重新拉取。另外每 45 秒会再刷一次，免得漏掉一帧。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("通知") {
                    Toggle("新消息提醒", isOn: Binding(
                        get: { app.notificationsEnabled },
                        set: { enabled in
                            Task { notice = await app.setNotificationsEnabled(enabled) }
                        }
                    ))
                    Text("你正看着的那个会话不会再弹通知。系统挂起之后，回到前台会重连并补拉。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let notice {
                    Section { NoticeBanner(message: notice) }
                }
                Section {
                    Button("退出登录", role: .destructive) { app.logout() }
                }
            }
            .navigationTitle("我的")
            .scrollContentBackground(.hidden)
            .background(Theme.paper)
            .onAppear {
                nickname = app.user?.nickname ?? ""
                server = app.baseURL
            }
            .onChange(of: picker) { _, item in
                guard let item else { return }
                Task { await upload(item) }
            }
        }
    }

    private func saveNickname() async {
        busy = true
        notice = await app.saveNickname(nickname) ?? "昵称已保存。"
        busy = false
    }

    private func upload(_ item: PhotosPickerItem) async {
        busy = true
        defer { busy = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                notice = "没有读到图片。"
                return
            }
            let url = try AvatarImage.jpegDataURL(from: data)
            notice = await app.uploadAvatar(dataURL: url) ?? "头像已更新。"
        } catch {
            notice = APIErrorText.describe(error, baseURL: app.baseURL)
        }
    }
}
