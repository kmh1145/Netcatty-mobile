# 项目结构与文件职责

## 仓库目录

```text
Netcatty-mobile/
├─ .github/
│  └─ workflows/mobile.yml       Android/iOS CI、签名 APK 与无签名 IPA
├─ android/                       Android Flutter Host 与原生能力
├─ assets/
│  ├─ distro/                    Linux/Unix 发行版图标
│  └─ docker/                    Docker 镜像品牌图标
├─ docs/                          开发文档与 README 截图
├─ ios/                           iOS Flutter Host 与原生能力
├─ lib/
│  ├─ application/               跨页面状态与生命周期
│  ├─ domain/                    数据模型和序列化
│  ├─ infrastructure/            网络、协议、存储与平台适配
│  └─ presentation/              页面、主题和组件
├─ test/                          单元测试与 Widget Test
├─ pubspec.yaml                   版本、依赖和资源声明
└─ README.md                      面向用户的项目入口
```

构建产物、Flutter 缓存、本地 SDK、签名文件和附件缓存均不属于源码，不得加入版本控制。

## 应用入口

| 文件 | 职责 |
| --- | --- |
| `lib/main.dart` | 初始化 Flutter、打开 `VaultRepository`、覆盖 Provider 并启动应用 |
| `lib/app.dart` | MaterialApp、主题、Locale 和应用级生命周期 |
| `lib/presentation/home_shell.dart` | 底部导航、五个主页面和终端全屏时的外壳隐藏逻辑 |

## Domain

`lib/domain` 只保存模型、枚举、序列化和轻量计算。

| 文件 | 主要类型 | 修改注意事项 |
| --- | --- | --- |
| `models/host.dart` | `HostProfile`、`SshKeyProfile`、`CommandSnippet`、`ProxyProfile` | 保留原始 Map 的未知字段；认证字段与安全存储键保持一致 |
| `models/vault.dart` | `VaultData` | 桌面/移动兼容的顶层保险库；新增字段需要兼容旧数据 |
| `models/settings.dart` | `AppSettings`、`SyncConnection`、`TerminalCustomKey` | 默认快捷键、AI 多模型列表与隐私开关迁移要有版本化测试 |
| `models/vault_sync_state.dart` | 记录级修订时钟、删除墓碑与本地变更标记 | 元数据位于加密 Payload 内，不得移动到明文 Envelope |
| `models/server_stats.dart` | `ServerSystemInfo`、`ServerStats` | 容忍远程采集缺字段 |
| `models/system_management.dart` | 进程、Docker、Compose、tmux 模型和枚举 | 与远程输出解析及 UI 操作保持一一对应 |

常见修改入口：

- 新增主机配置：先改 `HostProfile`，再改 `HostEditor`、`VaultRepository` 敏感字段处理和模型测试。
- 新增同步字段：先确认桌面端格式，再扩展 `VaultData`，不能覆盖未知字段。
- 新增快捷键：改 `AppSettings` 默认值/迁移和 `TerminalSpecialKeys`。

## Application

`lib/application` 管理共享状态，使用 Riverpod `StateNotifierProvider`。

| 文件 | 职责 |
| --- | --- |
| `vault_controller.dart` | Vault 加载、主机/密钥/片段/代理的增删改和持久化 |
| `session_controller.dart` | Pending 连接、活动终端、标签、分屏、关闭与连接平台状态 |
| `settings_controller.dart` | 主题、视图、终端快捷键等设置的保存 |
| `port_forward_controller.dart` | SSH 本地转发、动态 SOCKS5 的活动状态与停止 |

如果一个异步状态必须在多个页面间一致，应由 Controller 持有。仅属于弹窗或单个列表请求的短生命周期状态可以留在 StatefulWidget。

## Infrastructure

### SSH 与远程管理

| 文件 | 职责 |
| --- | --- |
| `ssh/ssh_service.dart` | SSH/Telnet 连接、认证、主机指纹、代理、跳板机、Shell 和端口转发底层 |
| `ssh/server_monitor_service.dart` | 系统识别与 CPU/内存/磁盘/网络/负载采集 |
| `ssh/sftp_service.dart` | `FileTransferService`、远程/本地文件实现、递归传输、进度和 iOS 有界并发 |
| `ssh/android_document_tree_service.dart` | Android SAF Dart 适配器，通过 MethodChannel 读写授权目录 |
| `ssh/system_management_service.dart` | 进程信号、Docker、Compose、systemd/OpenRC、tmux 命令构造、权限探测和输出解析 |
| `ssh/connection_platform_service.dart` | 活动 SSH 会话与原生后台策略之间的桥接 |
| `ssh/terminal_picture_in_picture_service.dart` | Android/iOS PiP MethodChannel 封装 |

### 存储与同步

| 文件 | 职责 |
| --- | --- |
| `application/auto_sync_controller.dart` | 自动同步开关、修改防抖、前台/周期刷新、失败退避和并发修改保护 |
| `storage/vault_repository.dart` | SharedPreferences、安全存储、Vault/设置/同步连接的持久化 |
| `storage/background_image_service.dart` | 自定义背景复制、便携路径引用、旧 App 容器绝对路径迁移和清理 |
| `storage/vault_export_service.dart` | 保险库 JSON 选择路径、保存和取消处理 |
| `sync/netcatty_crypto.dart` | 桌面兼容 PBKDF2 + AES-GCM 加密格式 |
| `sync/cloud_sync_service.dart` | WebDAV/Gist/S3 下载、解密、合并、加密上传与 Gist 发现 |
| `sync/vault_merge_service.dart` | 按记录修订与墓碑合并多设备 Vault，解决删除复活和全量覆盖 |
| `sync/github_auth_service.dart` | GitHub OAuth Device Flow、轮询、网络重试和用户信息读取 |
| `http_client_provider.dart` | 共享 HTTP Client、统一请求超时和连接复用 |
| `update_check_service.dart` | GitHub Latest Release 查询、版本比较和安全下载链接 |

### AI

| 文件 | 职责 |
| --- | --- |
| `ai/ai_service.dart` | OpenAI 兼容聊天请求、最近 30 条多轮上下文、可选终端输出、普通文本/命令建议解析 |

基础设施层处理外部输入时要先验证类型和边界。Shell 参数必须转义，HTTP 错误不能把 Authorization Header 写入日志。

## Presentation

### 页面

| 文件 | 页面职责 |
| --- | --- |
| `screens/vault_screen.dart` | 主机搜索、筛选、网格/列表/树形视图、连接详情与编辑入口 |
| `screens/terminal_screen.dart` / `terminal_screen_pane.dart` | Pending 弹窗、多标签、终端输入、分屏、全屏、选区和底部工具栏 |
| `screens/sftp_screen.dart` / `sftp_screen_pane.dart` | 单/双栏来源选择、文件操作、跨服务复制、续传和传输进度 |
| `screens/snippets_screen.dart` | 命令片段列表、新增、编辑和发送 |
| `screens/settings_screen.dart` / `settings_screen_dialogs.dart` | 云同步与自动同步、GitHub 登录、主题、自定义背景、语言、安全键盘、导入导出与应用版本 |

### 通用组件

| 文件 | 职责 |
| --- | --- |
| `widgets/host_editor.dart` | 完整连接编辑表单、键盘滚动、认证/跳板机/代理/高级选项 |
| `widgets/keychain_sheet.dart` | SSH 密钥管理 |
| `widgets/host_system_icon.dart` | 根据系统识别信息选择图标 |
| `widgets/terminal_special_keys.dart` | 默认/自定义快捷键、修饰键状态、自动换行与编辑器 |
| `widgets/ai_chat_sheet.dart` | Catty 多轮聊天、模型切换、终端输出共享状态、会话独立历史、命令复制/定向粘贴与执行确认 |
| `widgets/server_monitor_sheet.dart` | 性能监控面板 |
| `widgets/port_forward_sheet.dart` | 端口转发配置和活动转发列表 |
| `widgets/empty_state.dart` | 通用空状态 |

### 系统管理组件

```text
presentation/widgets/system_management/
├─ system_management_sheet.dart   进程 / Docker / 服务 / tmux 顶层 Tab
├─ process_manager_panel.dart      进程筛选、排序、详情与信号操作
├─ docker_manager_panel.dart       容器 / 镜像管理
├─ docker_compose_panel.dart       Compose 项目与常用操作
├─ docker_image_badge.dart         镜像品牌识别与图标
├─ service_manager_panel.dart      systemd / OpenRC 服务筛选与操作
├─ management_filter_chip.dart     系统管理页共用状态筛选标签
└─ tmux_manager_panel.dart         Session / Window / Client 管理
```

### 主题

`presentation/theme.dart` 保存 `NetcattyThemePreset` 列表和 Material Theme 生成逻辑。新增主题时检查主题搜索、选择卡片、终端颜色、错误色和文字对比度。

### 本地化

`presentation/localization/` 提供中英文文案解析和本地化 Widget。新增用户可见中文文案后必须补充英文翻译；`localization_coverage_test.dart` 会扫描源码并阻止遗漏进入 CI。

## Android 原生工程

关键路径：`android/app/src/main/kotlin/app/netcatty/mobile/`

| 文件 | 职责 |
| --- | --- |
| `MainActivity.kt` | 注册连接、存储和 PiP MethodChannel，通知权限与 PiP 状态 |
| `SshKeepAliveService.kt` | 活动 SSH 会话的前台服务通知 |
| `DocumentTreeChannel.kt` | SAF 目录挂载、权限持久化、列出、缓存桥接、创建、重命名和删除 |

`AndroidManifest.xml` 声明网络、通知、前台服务、PiP 和 `ssh://` Intent。增加原生能力时同时检查 Android 版本条件、运行时权限、导出属性和后台限制。

Release 签名由 `android/app/build.gradle.kts` 读取环境变量；签名文件不能进入 Git。

## iOS 原生工程

| 文件 | 职责 |
| --- | --- |
| `ios/Runner/AppDelegate.swift` | Background Task、PiP 通道、终端帧渲染和 AVPictureInPictureController |
| `ios/Runner/SceneDelegate.swift` | Flutter Scene 生命周期入口 |
| `ios/Runner/Info.plist` | 文件共享、URL Scheme、PiP/音频背景模式、方向与隐私描述 |

iOS 本地目录由 Dart 的 `LocalFileTransferService` 使用 App Documents 实现，不使用 Android SAF。修改 `Info.plist` 的文件共享键后要在“文件”App 真机验证。

## Assets

```text
assets/
├─ distro/    系统/发行版 SVG 图标
└─ docker/    Docker 镜像品牌 SVG 图标
```

`pubspec.yaml` 当前声明整个 `assets/`、`assets/distro/` 和 `assets/docker/`。不要把用户截图、密钥或下载缓存放入运行时 Assets；README 截图属于 `docs/images/`。

## Tests

`test/` 中每个文件对应一个边界：

- 模型与 Vault 无损往返
- 桌面端加密兼容
- GitHub Device Flow
- GitHub Release 更新检查与版本比较
- 主机编辑器和终端连接 UI
- SFTP/快捷键/PiP 可用性
- 系统管理命令与解析
- Vault 导出
- Vault 多设备合并、删除墓碑与终端软键盘修饰键
- 中英文文案覆盖

新增远程命令解析器或数据迁移时，应先加入纯 Dart 测试；新增布局修复时加入固定屏幕尺寸的 Widget Test。

## CI 与文档

| 路径 | 职责 |
| --- | --- |
| `.github/workflows/mobile.yml` | PR/main 自动分析、测试、Android 签名 APK、iOS 无签名 IPA |
| `README.md` | 用户功能、截图、下载与快速开发入口 |
| `docs/ARCHITECTURE.md` | 依赖与数据流 |
| `docs/DEVELOPMENT.md` | 环境、测试、CI 和发布 |
| `docs/SECURITY.md` | 安全边界和隐私检查 |

改变行为时同步更新对应文档，不要只更新 README 的功能列表。

## 常见任务入口

| 任务 | 首先检查 |
| --- | --- |
| 新增连接字段 | `host.dart` → `host_editor.dart` → `vault_repository.dart` → 模型测试 |
| 修改终端标签 | `session_controller.dart` → `terminal_screen.dart` → 连接弹窗测试 |
| 增加快捷键 | `settings.dart` → `terminal_special_keys.dart` → SFTP/终端可用性测试 |
| 修改 SFTP | `sftp_service.dart` → Android DocumentTree 适配 → `sftp_screen.dart` → 流式测试 |
| 修改云同步 | `cloud_sync_service.dart` / `netcatty_crypto.dart` → 兼容测试 → 设置页 |
| 增加系统管理操作 | `system_management.dart` → `system_management_service.dart` → Panel → 服务测试 |
| 修改后台/PiP | Dart 平台服务 → Android MainActivity/Service → iOS AppDelegate → 双平台 CI/真机 |
| 发布版本 | `pubspec.yaml` → README/Docs → 完整验证 → main CI → Tag/Release |
