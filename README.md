# Netcatty Mobile

Netcatty 的 Android / iOS 移动端。项目沿用桌面版的深色工作台视觉、Vault 数据模型和 `netcatty-vault.json` 零知识加密同步格式，移动端使用 Flutter、dartssh2 与 xterm.dart 原生重建。

## 已实现

- Vault 主机管理：搜索、分组、网格/列表、置顶字段与桌面版未知字段无损往返
- SSH：密码、OpenSSH/PEM 私钥、私钥口令、keyboard-interactive/MFA、环境变量、启动命令、保活、超时配置
- 主机密钥：连接时显示算法与 SHA-256 指纹，拒绝后立即终止握手
- Telnet：基础交互会话和 Telnet option 协商
- 终端：多会话标签、横/竖分屏、中文输入、触控扩展键、10,000 行回滚
- SFTP：目录浏览、新建、上传、下载/分享、重命名、删除、文本文件远程编辑
- 端口转发：SSH 本地转发和动态 SOCKS5
- 命令片段：保存、编辑、发送或自动执行
- Catty Agent：OpenAI 兼容接口、主机上下文、命令解释、执行前确认
- 安全存储：Android Keystore / iOS Keychain 分离保存密码、私钥、同步密码和 API Key
- 云同步：WebDAV 与 GitHub Gist；PBKDF2-SHA256 600,000 次 + AES-256-GCM，兼容桌面端文件
- 数据迁移：桌面端解密 JSON 导入、完整 JSON 导出、插件侧车及未来字段保留
- Android/iOS 原生工程、CI、加密兼容向量测试

## 平台边界

桌面版的本地 PTY、串口、Eternal Terminal、Electron 插件沙箱和外部桌面 Agent SDK 依赖桌面操作系统或 Node/Electron，移动系统不能按原实现直接运行。移动端保留这些协议/插件字段，云同步不会删除它们；Mosh 入口会明确提示需要后续接入 GPL 兼容的 iOS/Android UDP 原生运行时。SSH、SFTP、Vault、同步、端口转发、片段和 Catty 是当前可运行的移动功能主体。

## 开发环境

- Flutter 3.44.4 或更高稳定版
- Dart 3.12 或更高
- Android Studio / Android SDK（Android）
- macOS + Xcode 16+ + CocoaPods（iOS）

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

Android 构建：

```bash
flutter build apk --release
flutter build appbundle --release
```

iOS 构建（需先在 Xcode 设置开发团队和签名）：

```bash
flutter build ios --release
open ios/Runner.xcworkspace
```

发布前请把 `android/app/build.gradle` 的 debug signingConfig 替换成正式签名，并在 Xcode 设置唯一 Bundle ID、Team、App Store 图标和隐私清单。

## 与桌面端同步

在桌面 Netcatty 和移动端填写相同的 WebDAV/Gist 位置与同步主密码。移动端读取桌面端 v1/v2 文件时会解密 materialized payload 并保留未知字段；移动端写回时生成桌面端可迁移的兼容快照，桌面端下次同步会重建 convergent-sync v2 副本。

敏感数据会进入加密云端文件，但本机明文只存于系统安全存储。不要把“导出保险库 JSON”交给不可信应用，因为该手动导出文件可包含凭据。

## 目录结构

```text
lib/domain          无副作用数据模型
lib/application     Vault、会话和端口转发状态
lib/infrastructure  安全存储、SSH/SFTP、同步、AI 适配器
lib/presentation    移动端页面与组件
android / ios       原生宿主工程
test                加密兼容与模型无损测试
```

## License

GPL-3.0-or-later，延续上游 [binaricat/Netcatty](https://github.com/binaricat/Netcatty) 的许可证。

