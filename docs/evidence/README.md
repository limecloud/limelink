# 来源与证据边界

本目录分别保存研究快照、图形、文档检查、产品源码构建、网关联调、macOS 原生窗口及宣传站证据。每份记录只证明自身范围；构建或软件手机夹具不等于真实手机、正式发行或硬件验收。

## 记录类型

| 文件 | 用途 |
| --- | --- |
| [sources.json](sources.json) | 来源 ID、仓库、路径、读取范围、支持与不支持的结论 |
| [upstream-snapshot.json](upstream-snapshot.json) | 各参考仓库 HEAD、实际文件 SHA-256、与 HEAD 是否相同 |
| [diagram-rendering.json](diagram-rendering.json) | Mermaid 到 SVG 的工具、源码和输出摘要及视觉检查范围 |
| [documentation-verification.json](documentation-verification.json) | 当前独立文档检查的实际结果、错误与待复验范围 |
| [website-browser.json](website-browser.json) | 宣传站浏览器检查摘要，不含本机绝对路径 |
| [website-deployment.json](website-deployment.json) | 独立 Cloudflare Worker、版本、制品与域名核验 |
| [coverage.md](coverage.md) | 知识与工程维度覆盖及未核验项 |

来源元数据只保留仓库和相对路径，不发布本机绝对路径或个人凭据。远端链接用于导航；若参考文件有未提交修改，公开 commit 链接不能保证提供相同字节，实际观察以快照摘要和状态说明为准。

## 产品实现证据

| 文件 | 实际证明与限制 |
| --- | --- |
| [native-ci.json](native-ci.json) | GitHub 的四端构建与 Linux 集成结果，绑定实际 commit；不代表真机或发行签名 |
| [native-validation.json](native-validation.json) | 本机构建/核心检查的退出码、范围、源码与日志摘要，分别标记通过、失败与环境阻塞；不是真机 |
| [android-gateway-discovery.json](android-gateway-discovery.json) | 当前 SDK 的 Android 16 组共享公告解析样例、附加边界测试与 APK 构建；系统 NSD 生命周期未验收，真机局部旅程另行记录 |
| [android-mobile-ui.json](android-mobile-ui.json) | USB真机安装、三页界面、手动地址/键盘、公网HTTPS登录、会话恢复与在线电脑列表的局部检查；配对面板完整展开、键盘上方主按钮及未连接设置面板已真机复验，完整配对/Agent/iOS尚未通过 |
| [android-mobile-flow.json](android-mobile-flow.json) | 分阶段记录新 SDK 真机配对与真实只读任务、最终 UI 两页键盘与精简安装/连接实测；同一卡片由 queued 到窗口实际可见后的 presented 已补充取证，最终源码完整最小化/恢复旅程未完成，整体保持未通过 |
| [android-transport-recovery.json](android-transport-recovery.json) | IoT Android GET连接恢复、POST零重发、有界失败与不完整正文异常，固定提交核心回归；不代表公网断流根因或手机完整旅程 |
| [local-gateway-installation.json](local-gateway-installation.json) | 当前 SDK 的新目录安装复验失败：本机 Docker 地址池耗尽；旧安装通过记录保存在 history，不作为当前通过依据 |
| [gateway-management-macos-ui.json](gateway-management-macos-ui.json) | macOS 统一安装管理入口、本机启停、配置恢复、执行端连接、Agent 默认关闭，以及公网/内网普通原生安装引导；首次图形安装和最终入口复验分阶段记录 |
| [native-gateway-server.json](native-gateway-server.json) | 用户授权 Ubuntu 22.04 amd64 主机普通安装，17 项 systemd、回环 TLS/登录、mTLS、私钥隔离与重启检查；无 Docker、无公网/手机验收 |
| [iot-runtime-mtls-integration.json](iot-runtime-mtls-integration.json) | 固定 IoT 与 Rust 实际 HTTP/MQTT/mTLS；批准、呈现和手机由软件夹具驱动 |
| [macos-native-ui.json](macos-native-ui.json) | 当前 SDK 与源码的原生配对、卡片呈现回执、电脑会话编辑/释放和软件手机接续查询 |
| [agent-gateway-integration.json](agent-gateway-integration.json) | 当前三种产品核心的无设备工具 Agent 协议夹具、真实隔离网关与 mTLS；软件批准 |
| [pairing-receipt-recovery.json](pairing-receipt-recovery.json) | 当前 SDK 的配对收尾、Android 普通协同终态和成功卡片草稿检查；三种客户端 mTLS 协议夹具通过，真实模型和目标窗口另行验收 |
| [agent-gateway-live.json](agent-gateway-live.json) | 当前 SDK 的真实 Codex 无设备工具三端 mTLS 核心旅程通过；无原生窗口或真手机，真实中断另行验收 |
| [agent-iot-macos-ui.json](agent-iot-macos-ui.json) | 当前 macOS 原生 Agent 配对、提交、本机批准与逐次设备确认；独立模拟灯，开发鉴权链路 |
| [agent-settings-macos-ui.json](agent-settings-macos-ui.json) | macOS 设置页从无 Agent 配置启用并保存重连，再完成真实模型/网关/模拟灯任务；设备身份保持、文件权限 0600 |
| [agent-settings-windows-core.json](agent-settings-windows-core.json) | Windows 本机助手设置源码、18 组 .NET 核心检查和 WinUI C# 类型检查；运行于 macOS，Windows ACL、XAML 构建与窗口未验收 |
| [cloud-workbench-ui.json](cloud-workbench-ui.json) | 当前 Apple 实际工作台模型经真实 HTTPS/WSS/MQTT/mTLS 的云旅程；没有原生窗口或真手机 |
| [regression-2026-11-06.json](regression-2026-11-06.json) | 保留真实模型与卡片回执的原始失败；补充当前 SDK 三端无设备工具真实模型通过记录，以及卡片呈现补充复验范围 |
| [content-retention.json](content-retention.json) | 协同库正文和缓存回执到期清理、明确 v1 迁移、读者占用与重启恢复、活动数据库/WAL 夹具扫描；不含 Agent 库、平台或备份清除 |
| [agent-content-retention.json](agent-content-retention.json) | Agent 正文/工具/缓存回执清理事务回滚、迟到消息拒绝、旧空闲页整理、WAL 读者与重启恢复、原引用保持及活动文件夹具扫描；不含平台、Codex 或备份清除 |

普通 HTTP 的早期 iot-runtime-integration.json 保留历史范围；当前发布评估优先读取包含源码/二进制摘要的 mTLS 记录。上游平台补丁和消费锁见 [IoT 接入](../12-gateway-integration.md)。

本轮调整了 App、设置和工作台入口。四份已有 macOS 任务证据保留原入口的历史摘要，其他未变的协议与执行源码继续校验；当前入口、共享控制器和助手设置布局由 `gateway-management-macos-ui.json` 的实际窗口复验绑定。旧真实模型任务没有在本轮重复执行，不能将入口复验描述成新修订的模型整套通过。

手机安装和 Android 界面重做又改变了部分入口。发现解析、配对收尾、Apple云工作台和本机网关旧证据保留这些文件的历史摘要。新 SDK 的编译另引用 `native-validation.json`，公网手机配对、卡片和真实只读任务另引用 `android-mobile-flow.json`。当前 SDK 的三端无设备工具真实模型任务已单独复验通过，见 `agent-gateway-live.json`；旧的完整云旅程、本机图形安装及部分原生窗口尚未复验，旧记录的修订或源码不匹配仍是当前文档检查失败项。

当前 SDK 的公告解析、配对收尾、Windows 配置核心与 C# 类型检查、三种云核心、三种客户端 mTLS 和设备工具协议夹具已实际复验，并更新各自范围内的记录；被替换记录保存在 `history/2026-11-06-sdk-core-revalidation/`。远程连接探测的三组正反例也已重新通过。本机新目录安装本轮失败，未通过删除用户网络或修改校验规则改变结果。上述复验不包含真实模型、原生窗口或手机；手机界面检查按阶段另行记录。

## 研究与文档执行范围

研究阶段已克隆仓库、读取参考文件，使用用户指定图片服务生成 28 张图并实现宣传站。随后已进入软件实施：四端原生工程通过 CI 构建，隔离的真实 IoT 网关与 Rust 执行端完成命令联动，macOS 原生窗口取得局部验证。完整产品用例目前为 `partial` 或 `not_run`，不能把局部检查等同全部验收；没有采购、制作或操作硬件。

文档检查为 Python 标准库程序。图形使用 Mermaid CLI 11.12.0 和本机浏览器导出，保留 `.mmd` 与 SVG。渲染工具来自已有本机缓存，记录实际工具版本；文档校验不依赖该缓存。源码与 SVG 的摘要关系由校验脚本检查，实际渲染与视觉审阅另行记录。

## 后续更新

更新参考结论时，定向重新读取受影响文件并产生新快照。原来源的检查日期不自动变成新日期。进入软件阶段后增加与具体 commit/工作树和制品绑定的运行记录，不将文档结果改名为 E2E 通过。

本轮不为远端链接做全量网络可达性检查，文件摘要也不是上游发布签名。当前快照是研究证据，不是可安装的 SDK 供应链锁。

- [公网原生网关](public-native-gateway.json)：受信 HTTPS、所有者登录、设备 mTLS、匿名拒绝与实际桌面执行端上线；不代表手机或 Agent 任务已验收。
- [远程安装连接检查](remote-gateway-probe.json)：公网可达、未受信证书拒绝与关闭端口三组检查。
