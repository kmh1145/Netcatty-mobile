# 开发、测试与发布流程

## 环境要求

| 工具 | 建议版本 | 用途 |
| --- | --- | --- |
| Flutter | 3.44.4 | 与 GitHub Actions 保持一致 |
| Dart | Flutter 自带版本 | 格式化、分析、测试 |
| JDK | 17 | Android Gradle 构建 |
| Android SDK | Flutter 当前稳定版支持的 SDK | APK/AAB 与真机调试 |
| Xcode | 16+ | iOS 构建，仅 macOS |
| CocoaPods | 当前稳定版 | iOS Plugin 依赖 |
| GitHub CLI | 当前稳定版 | PR、Actions Artifact 和 Release |

优先使用仓库 CI 相同的 Flutter 版本。升级 Flutter、Gradle、Kotlin、Xcode 或依赖时应单独提交，并同时验证 Android 与 iOS。

Windows 工作区路径包含空格时，某些 Native Asset Hook 可能错误截断命令。遇到类似问题时，优先把仓库放到无空格路径，或用短盘符映射同一个工作区后重新执行 `flutter pub get`；不要修改源码来绕过本机路径问题。

## 初始化

```bash
git clone https://github.com/kmh1145/Netcatty-mobile.git
cd Netcatty-mobile
flutter pub get
flutter doctor -v
```

GitHub Device Flow 在编译期读取 `GITHUB_OAUTH_CLIENT_ID`：

```bash
flutter run --dart-define=GITHUB_OAUTH_CLIENT_ID=<your-client-id>
```

OAuth App 需要启用 Device Flow，作用域由应用请求 `gist read:user`。Client ID 可以随客户端分发，Client Secret、访问 Token 和用户授权码不得写入源码、文档、Issue 或日志。

## 日常开发命令

```bash
flutter pub get
dart format lib test
flutter analyze
flutter test
flutter run
```

提交前的无修改格式检查：

```bash
dart format --output=none --set-exit-if-changed lib test
```

只运行相关测试示例：

```bash
flutter test test/sftp_terminal_usability_test.dart
flutter test test/system_management_service_test.dart
flutter test test/github_auth_service_test.dart
```

## 构建

### Android

Debug APK：

```bash
flutter build apk --debug
```

Release APK / App Bundle：

```bash
flutter build apk --release \
  --dart-define=GITHUB_OAUTH_CLIENT_ID=<your-client-id>
flutter build appbundle --release \
  --dart-define=GITHUB_OAUTH_CLIENT_ID=<your-client-id>
```

签名信息通过环境变量或本机忽略文件提供。不要提交 `.jks`、`key.properties`、证书密码或 Base64 编码后的签名文件。

### iOS

无签名可重签 App：

```bash
flutter build ios --release --no-codesign \
  --dart-define=GITHUB_OAUTH_CLIENT_ID=<your-client-id>
```

在 macOS 中把 `build/ios/iphoneos/Runner.app` 放入 `Payload/` 后压缩即可生成可重签 IPA。App Store 或 TestFlight 构建需要自己的 Bundle ID、Team、Provisioning Profile 和分发证书。

Windows 无法完成原生 iOS 编译；涉及 Swift、Info.plist 或 iOS Plugin 的修改必须以 macOS CI 结果为准，并尽量在真机验证文件共享、Keychain、PiP 与后台生命周期。

## 测试矩阵

| 测试文件 | 重点覆盖 |
| --- | --- |
| `vault_model_test.dart` | Vault 字段、未知字段无损往返和模型迁移 |
| `vault_loading_test.dart` | 保险库快照优先显示与后台敏感字段加载 |
| `netcatty_crypto_test.dart` | 桌面端兼容加密向量与 AES-GCM 格式 |
| `github_auth_service_test.dart` | Device Flow、轮询、重试、取消与网络错误 |
| `update_check_service_test.dart` | GitHub Latest Release 解析、语义版本比较与网络错误 |
| `vault_export_service_test.dart` | JSON 导出与取消路径 |
| `host_editor_layout_test.dart` | 键盘弹出、滚动和窄屏表单布局 |
| `terminal_connection_dialog_test.dart` | Pending 标签、连接弹窗和会话隔离 |
| `sftp_terminal_usability_test.dart` | SFTP 递归传输、进度、零拷贝、快捷键与 PiP 文本 |
| `system_management_service_test.dart` | 进程、Docker、Compose、tmux 命令与解析 |
| `mobile_v1_features_test.dart` | 关键移动端功能回归 |

协议解析、Shell 参数转义、模型序列化和控制器状态转换优先写单元测试。触屏布局问题应补充固定窗口尺寸的 Widget Test，并使用 `tester.takeException()` 检查 RenderFlex Overflow。

## 真机回归清单

### 通用

- 密码、私钥、跳板机和代理连接
- 同一主机打开两个以上标签，关闭确认和分屏
- 中文输入、文本选择、拖动选区、复制与粘贴
- 性能面板与系统识别
- 进程、Docker/Compose 和 tmux 操作的确认弹窗
- WebDAV、GitHub Gist 与 S3 的统一立即同步及条件写入
- 桌面端兼容的三方合并、加密共同 base、删除墓碑和 PC 删除数据不复活回归
- 自动同步开关、修改防抖、前台刷新、失败重试及同步期间继续编辑
- 保险库导入/导出

### Android

- Android 13+ 通知权限和 SSH 前台服务
- 进入后台、返回前台和系统省电限制下的连接行为
- SAF 目录选择、权限持久化、上传/下载和大文件进度
- 窄屏双栏 SFTP 工具栏不越界
- 画中画进入、退出和终端方向
- 使用 CI 签名 APK 覆盖安装上一版本

### iOS

- “文件”App 中出现 Netcatty 文件夹，并能读写上传/下载文件
- 无签名 IPA 重签后安装
- Keychain 数据在升级后保留
- PiP 文字方向、颜色、更新和停止
- 大文件 SFTP 时界面保持响应，进度平稳更新
- 前后台切换后的 SSH 状态和系统回收提示

## 分支与提交

- 新功能和较大的 Bug 修复使用独立分支，例如 `codex/sftp-progress`，通过 PR 和 CI 合并。
- 很小且边界明确的文档、版本或维护修改，可按维护者要求直接在 `main` 完成，避免为每个微小改动积累分支。
- 一个 PR 只包含一个可解释的目标；不要使用 `git add -A` 把附件、构建产物或用户未提交修改一并加入。
- PR 合并后删除远端功能分支。
- 提交信息使用简洁的 Conventional Commit 风格，例如 `feat: add SFTP progress`、`fix: constrain dual-pane toolbar`、`docs: add development guide`。

## GitHub Actions

`.github/workflows/mobile.yml` 在 PR 和 `main` Push 时运行：

### test Job

1. `flutter pub get`
2. 格式检查
3. `flutter analyze`
4. `flutter test`
5. 使用持久 Android 签名构建通用 APK，以及 `arm64-v8a`、`armeabi-v7a`、`x86_64` 三个分架构 APK
6. 为每个 APK 生成 SHA-256 并上传 Artifact

需要的 Secrets：

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_PASSWORD`

### ios Job

1. 无签名构建 Release iOS App
2. 打包 `netcatty-mobile-vX.Y.Z-ios-unsigned.ipa`
3. 生成 SHA-256 并上传 Artifact

Android 通用安装包命名为 `netcatty-mobile-vX.Y.Z-android.apk`，分架构包分别追加 `-arm64-v8a`、`-armeabi-v7a`、`-x86_64`。现代实体设备优先提供 `arm64-v8a`，无法确认架构时使用通用包。Artifact 默认保留 30 天，Artifact 名称还会追加 Actions Run Number 以便区分同版本的不同构建。CI 的 Android `versionCode` 使用 Actions Run Number，以保证同一签名下可覆盖升级；正式 Release 的用户可见版本和安装包文件名均由 `pubspec.yaml` 的 Build Name 决定。

## 版本号

版本只在 `pubspec.yaml` 中维护：

```yaml
version: MAJOR.MINOR.PATCH+BUILD
```

- `MAJOR.MINOR.PATCH` 映射 Android `versionName`、iOS `CFBundleShortVersionString`。
- `BUILD` 映射 Android `versionCode`、iOS `CFBundleVersion`；本地发布时必须单调增加。
- 设置页底部通过 `package_info_plus` 读取构建信息，不要再硬编码一份版本字符串。

修改版本后运行一次 `flutter pub get`，并检查 Android/iOS 构建输出与设置页。

## Release 流程

1. 确认目标 PR 已合并，`main` 与 `origin/main` 一致。
2. 更新 `pubspec.yaml` 的版本和 Build Number。
3. 更新 README、开发文档和 Release Notes。
4. 执行格式检查、`flutter analyze`、完整 `flutter test` 和本地 Android 构建。
5. 推送 `main`，等待 Mobile CI 的 test 与 ios Job 全部成功。
6. 下载同一次 CI Run 的 Android/iOS Artifacts，确认包含：
   - `netcatty-mobile-vX.Y.Z-android.apk`（通用包）
   - `netcatty-mobile-vX.Y.Z-android-arm64-v8a.apk`
   - `netcatty-mobile-vX.Y.Z-android-armeabi-v7a.apk`
   - `netcatty-mobile-vX.Y.Z-android-x86_64.apk`
   - 每个 APK 对应的 `.sha256`
   - `netcatty-mobile-vX.Y.Z-ios-unsigned.ipa`
   - `netcatty-mobile-vX.Y.Z-ios-unsigned.ipa.sha256`
7. 创建带注释的 `vX.Y.Z` Tag，并以同名 GitHub Release 发布全部安装包和校验文件。
8. 检查 `/releases/latest`、README 徽章、安装包下载和校验文件。

示例命令中的 Run ID 和版本必须替换为当前值：

```bash
gh run download <run-id> --dir dist
git tag -a vX.Y.Z -m "Netcatty Mobile X.Y.Z"
git push origin vX.Y.Z
gh release create vX.Y.Z <assets...> --title "Netcatty Mobile X.Y.Z" --notes-file <notes.md>
```

不要在 CI 未通过时提前移动 `latest` Tag，也不要上传来自不同提交或不同 CI Run 的 Android/iOS 包。

### Beta / 预发布流程

Beta 版本必须同时满足以下约束：

1. `pubspec.yaml` 使用预发布版本，例如 `1.4.0-beta.1+15`。
2. Git Tag 使用对应名称，例如 `v1.4.0-beta.1`。
3. GitHub Release 必须标记为 Pre-release；CLI 发布时必须添加 `--prerelease`：

```bash
gh release create vX.Y.Z-beta.N <assets...> --prerelease --title "Netcatty Mobile X.Y.Z Beta N" --notes-file <notes.md>
```

应用内更新检查固定使用 GitHub `/releases/latest` 正式版通道，并额外拒绝响应中的 Draft/Pre-release，因此普通用户不会收到 Beta 更新提示。Beta 测试用户需要从 Releases 页面或对应 PR 的 Actions Artifacts 手动下载安装。仅使用 `-beta.N` 标签但遗漏 `--prerelease` 会被 GitHub 当作正式 Release，严禁这样发布。

## 隐私与调试信息

提交或发布前搜索并清理：

- 真实 IP、域名、用户名、邮箱、主机别名和主机指纹
- GitHub Token、WebDAV 密码、同步主密码、AI API Key
- 私钥、证书、Provisioning Profile 和 Android Keystore
- 截图通知栏、终端历史、登录来源 IP 和文件路径
- 开发者绝对路径、临时目录和附件缓存目录

文档截图只使用已脱敏版本，并检查 EXIF/设备元数据。日志示例应使用 `example.com`、`192.0.2.0/24` 等保留示例地址。
