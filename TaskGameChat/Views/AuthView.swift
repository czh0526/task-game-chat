import SwiftUI
import UIKit

struct AuthView: View {
    @Environment(AppModel.self) private var app
    @State private var mode = 0
    @State private var email = ""
    @State private var password = ""
    @State private var nickname = ""
    @State private var server: String = ""
    @State private var notice: String?
    @State private var busy = false
    @State private var pinging = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("任务会话")
                            .font(.largeTitle.bold())
                        Text("用邮箱登录，和好友、任务里的人说话。")
                            .foregroundStyle(.secondary)
                    }
                    Picker("方式", selection: $mode) {
                        Text("登录").tag(0)
                        Text("注册").tag(1)
                    }
                    .pickerStyle(.segmented)
                    NoticeBanner(message: notice ?? app.authBanner)
                    field("邮箱", text: $email, content: .emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                        .textContentType(mode == 0 ? .password : .newPassword)
                        .padding(12)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                    if mode == 1 {
                        field("昵称（可选）", text: $nickname, content: .nickname)
                    }
                    Button(action: submit) {
                        if busy {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text(mode == 0 ? "登录" : "注册并进入")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.ink)
                    .disabled(busy)
                    if app.hasStoredSession {
                        Button("重试上次的登录") {
                            Task { await app.retrySession() }
                        }
                        .disabled(busy)
                    }
                    DisclosureGroup("服务器") {
                        TextField("http://127.0.0.1:8891", text: $server)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .padding(12)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                        Text("模拟器里的 127.0.0.1 是这台 Mac。也可以写成带 /v1 的地址。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button(pinging ? "正在连接…" : "测试连接") {
                            Task { await testConnection() }
                        }
                        .disabled(pinging)
                    }
                    .padding(.top, 8)
                }
                .padding(20)
            }
            .background(Theme.paper)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if server.isEmpty { server = app.baseURL }
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, content: UITextContentType) -> some View {
        TextField(title, text: text)
            .textContentType(content)
            .padding(12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func submit() {
        notice = nil
        if let error = app.updateBaseURL(server) {
            notice = error
            return
        }
        guard let email = DisplayName.normalizedEmail(email) else {
            notice = "邮箱格式不正确。"
            return
        }
        if let error = DisplayName.passwordError(password) {
            notice = error
            return
        }
        var nick: String?
        if mode == 1 {
            let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let error = DisplayName.nicknameError(trimmed) {
                    notice = error
                    return
                }
                nick = trimmed
            }
        }
        busy = true
        Task {
            let message: String?
            if mode == 0 {
                message = await app.login(email: email, password: password)
            } else {
                message = await app.register(email: email, password: password, nickname: nick)
            }
            notice = message
            busy = false
        }
    }

    private func testConnection() async {
        if let error = app.updateBaseURL(server) {
            notice = error
            return
        }
        pinging = true
        notice = await app.ping()
        pinging = false
    }
}
