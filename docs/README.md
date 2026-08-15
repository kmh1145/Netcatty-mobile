# Netcatty Mobile 开发文档

本目录面向维护者和后续开发 Agent，记录项目当前实现、关键约束和可复用的验证流程。开始修改前先阅读与任务相关的文档，不要只根据页面名称猜测数据流。

## 文档导航

- [ARCHITECTURE.md](ARCHITECTURE.md)：分层、状态管理、SSH/SFTP、云同步、系统管理和原生桥接的数据流。
- [DEVELOPMENT.md](DEVELOPMENT.md)：环境搭建、开发命令、测试矩阵、分支约定、CI 与 Release 流程。
- [PROJECT_STRUCTURE.md](PROJECT_STRUCTURE.md)：仓库目录树、关键文件职责和常见修改入口。
- [SECURITY.md](SECURITY.md)：凭据存储、同步加密、主机验证、日志/截图脱敏和提交前安全检查。

## Agent 开发前检查

1. 运行 `git status -sb`，保留用户已有改动，不要清理不属于当前任务的文件。
2. 阅读目标模块、对应模型和现有测试；涉及原生能力时同时检查 Dart 与 Android/iOS 两端。
3. 修改 Vault 模型或同步格式时，必须保持未知 JSON 字段无损往返。
4. 修改 SSH 会话时，必须考虑多标签、分屏、SFTP、端口转发、性能监控和后台生命周期的共享关系。
5. 修改 SFTP 时，必须保持流式传输，不能把大文件整体读入内存；进度更新需要限频。
6. 不要把账号、IP、Token、私钥、主机指纹、签名文件、OAuth Secret 或未脱敏截图加入仓库。
7. 提交前至少执行格式检查、`flutter analyze` 和相关测试；发布前执行完整测试及 Android/iOS CI。

## 架构原则

- `domain` 保存可序列化模型，不依赖 Flutter UI。
- `application` 管理跨页面状态和生命周期。
- `infrastructure` 封装 SSH、SFTP、同步、安全存储、AI 和平台通道。
- `presentation` 负责交互与渲染，不应自行实现加密协议或拼接复杂远程管理命令。
- Android/iOS 原生代码只承担系统 API 无法由纯 Dart 完成的能力。

## 文档维护

功能、依赖方向、构建参数、CI Secret 名称、平台权限或目录结构发生变化时，应在同一提交中更新本目录。文档中只写变量名和示例占位符，不写真实凭据或维护者个人环境路径。
