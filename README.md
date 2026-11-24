# 任务会话

原生 iPhone 聊天客户端，对接 [Task Game Open Protocol](https://github.com/czh0526/task-game-api)。界面是中文。这一版只做账号、好友、会话和资料，不做任务市场、托管或 webhook。

对照的 API `main`：`563503d3579f413285291a657dafbbfbd4f37c63`（2026-11-24）。协议以当时的 `api/openapi.yaml` 为准；浏览器用的 SSE 不在 OpenAPI 里，实现跟 `internal/handler/events/streamHandler.go` 和 `web/src/eventStream.ts` 一致。

A native SwiftUI chat app for the Task Game API. The screen copy is Chinese. Build it on a Mac — this tree was prepared on Linux, where `xcodebuild` is not available.

## 在 Mac 上打开

需要 Xcode 16 或更新版本，以及 iOS 17 SDK。

1. 打开 `TaskGameChat.xcodeproj`。
2. 选一台 iPhone 模拟器。
3. 如果 Signing 提示要选 Team，在 target「TaskGameChat › Signing & Capabilities」里选你的开发团队。模拟器通常可以用本地签名。
4. Run。

Bundle id 是 `dev.taskgame.ios.chat`，显示名是「任务会话」。

## 连上本地 API

默认服务器是 `http://127.0.0.1:8891`，和仓库 `etc/taskgame.yaml` 的 `Port`、官方网页 `web/src/settings.ts` 一样。业务路径在 `/v1` 下面。地址写成 `http://127.0.0.1:8891/v1` 也可以，客户端会收成同一个 origin。

在 Mac 上启动 API（见 task-game-api 的 README，常见是 `docker compose up -d` 然后 `make run`）。模拟器里的 `127.0.0.1` 就是这台 Mac，不是模拟器自己。

API 如果跑在局域网另一台机器上，把地址改成那台机器的 IP。Info.plist 打开了 `NSAllowsLocalNetworking`，并允许 `localhost` 的 HTTP。公网地址请用 HTTPS，ATS 不会放行任意 HTTP。

登录页和「我的」里都能改地址，会记在本机。Bearer JWT 放在钥匙串，退出登录会删掉。

## 这个客户端会做什么

- 邮箱 + 密码注册、登录。密码按服务端规则：至少 8 个 Unicode 字符，最多 72 字节。邮箱会转成小写。
- 好友列表，包含个人分组、未读角标、收到和发出的申请。可以加好友、接受、拒绝、撤回、解除好友、建分组、改名、删除、把好友移进分组。
- 点一个好友会 `POST /v1/chats` `{ "type": "direct", "user_id" }`。已经有的一对一会话会返回同一条，状态仍是 201。
- 消息列表按接口从旧到新翻页，最多 20 页 × 100 条，和网页一样。发送文字；整条内容如果正好是内置表情，会以 `type: sticker` 发送。发出的消息马上插进当前会话，不等下一次整段刷新。
- 打开会话时用 `POST /v1/chats/{chatId}/read` 推进已读游标。每次用新的 `Idempotency-Key`，因为重复使用同一把钥匙不会覆盖后来的消息。
- 登录后一直保持 `GET /v1/events/stream`（`Accept: text/event-stream`、`Authorization: Bearer`、`Accept-Encoding: identity`）。这是一条不结束的连接，用 `URLSession` 的数据回调按块读取，避免系统把流缓冲到超时后拆掉。处理 `hello`、`resync`、`chat.message`。事件里只有 id。打开的会话把消息放在模型上，界面直接读这份列表：自己发出的马上插入，`chat.message` 到达后从最新一页往后补。`hello` 和 `resync` 才重拉整段。重连带 `Last-Event-ID`。另外每 45 秒拉一次好友，并给已经打开的会话补一次最新消息，防止丢帧。
- 别人发来消息、而你不在那个会话里时，可以弹本地通知。需要在「我的」里打开。
- `GET /v1/me`、`PATCH /v1/me` 改昵称，`PUT /v1/me/avatar` 上传头像。头像是单独的 JPEG：客户端先裁成 720×720，服务端还会再裁一次。展示用公开的 `GET /v1/users/{userId}/avatar`，不带头，404 时用色块首字。

声明了 `Idempotency-Key` 参数的写操作都会带上一枚新钥匙。`POST /register`、`POST /login`、`PATCH /me`、`PUT /me/avatar` 不带。

应用只配置一个 API 根地址。分片和 Redis 广播是服务端的事，客户端不做路由。

## 和文档对不上的地方

这些是读完当前 `main` 之后的取舍，不是猜的。

1. **显示名。** 提示里写的是有昵称时显示 `昵称(...后6位)`。当前 `web/src/person.ts` 已经改了：有昵称就只显示昵称，没有昵称才显示 `...` 加上用户 id 的最后 6 位。本应用跟现在的网页走。
2. **会话列表。** `GET /v1/chats` 必须带 `task_id`，而且只返回任务会话。一对一会话出现在 `GET /v1/friends` 的 `direct_chat_id` 上。没有「我参加的全部分组会话」接口。所以：好友的一对一会话会进收件箱；任务会话用任务编号打开；知道 `cht_` 编号可以直接打开。之后这台手机会记住。SSE 里出现的陌生会话也会补进收件箱。
3. **未读。** 服务端只在好友卡片上给出一对一的 `unread_count`。任务会话和多人会话的角标是本机根据 `chat.message` 计的，打开并标记已读后清掉。
4. **头像下载。** OpenAPI 把 `GET /users/{userId}/avatar` 标成公开。路由虽挂在鉴权中间件上，但 `isPublicRead` 在没有凭证时放行；带了凭证就会校验。图片请求因此不送 `Authorization`，避免过期令牌把头像打成 401。
5. **密码长度。** OpenAPI 写 `minLength: 8`、`maxLength: 72`。服务端 `Normalize` 实际是至少 8 个 Unicode 字符、最多 72 字节。客户端按服务端来。
6. **消息长度。** `text` 在服务端用 Go 的 `len`，上限 8000 字节。空文本会被拒绝。
7. **历史方向。** 分页从最旧的一页往后走，没有「直接取最新一页」的参数。超过 2000 条时，和网页一样只保留先读到的那一段，并提示被截断。
8. **SSE。** 帧格式是 `id`、`event: signal`、`data` 为 JSON。注释行 `: ping` 约 15 秒一次，解析时丢掉。`hello` 出现在第一次连接，带了 `Last-Event-ID` 的重连改成 `resync`。这两种都会触发重新拉取，不把它们当成一条聊天消息。

## 不做

发布和接受任务、托管、里程碑、争议、webhook、找回密码、真实货币。也没有把 TypeScript SDK 打进 App。

## 工程布局

```
TaskGameChat.xcodeproj
TaskGameChat/
  App/            入口和会话状态
  API/            手写的类型、REST 客户端、SSE
  Support/        显示名、表情、钥匙串、头像裁剪
  Views/          SwiftUI 界面
  Info.plist      本地 HTTP 的 ATS 例外
```
