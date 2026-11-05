# 来源与证据边界

本目录分别保存研究快照、图形、文档检查、产品源码构建、网关联调、macOS 原生窗口及宣传站证据。每份记录只证明自身范围；构建或软件手机夹具不等于真实手机、正式发行或硬件验收。

## 记录类型

| 文件 | 用途 |
| --- | --- |
| [sources.json](sources.json) | 来源 ID、仓库、路径、读取范围、支持与不支持的结论 |
| [upstream-snapshot.json](upstream-snapshot.json) | 各参考仓库 HEAD、实际文件 SHA-256、与 HEAD 是否相同 |
| [diagram-rendering.json](diagram-rendering.json) | Mermaid 到 SVG 的工具、源码和输出摘要及视觉检查范围 |
| [documentation-verification.json](documentation-verification.json) | 本轮独立文档检查、范围和通过结果 |
| [website-browser.json](website-browser.json) | 宣传站浏览器检查摘要，不含本机绝对路径 |
| [website-deployment.json](website-deployment.json) | 独立 Cloudflare Worker、版本、制品与域名核验 |
| [coverage.md](coverage.md) | 知识与工程维度覆盖及未核验项 |

来源元数据只保留仓库和相对路径，不发布本机绝对路径或个人凭据。远端链接用于导航；若参考文件有未提交修改，公开 commit 链接不能保证提供相同字节，实际观察以快照摘要和状态说明为准。

## 产品实现证据

| 文件 | 实际证明与限制 |
| --- | --- |
| [native-validation.json](native-validation.json) | 五项本机构建/核心检查的退出码、范围、源码与日志摘要；不是真机 |
| [iot-runtime-mtls-integration.json](iot-runtime-mtls-integration.json) | 固定 IoT 与 Rust 实际 HTTP/MQTT/mTLS；批准、呈现和手机由软件夹具驱动 |
| [macos-native-ui.json](macos-native-ui.json) | 真实 macOS 窗口批准、卡片呈现及会话编辑；手机仍为 Node 签名夹具 |

普通 HTTP 的早期 iot-runtime-integration.json 保留历史范围；当前发布评估优先读取包含源码/二进制摘要的 mTLS 记录。上游平台补丁和消费锁见 [IoT 接入](../12-gateway-integration.md)。

## 研究与文档执行范围

研究阶段已克隆仓库、读取参考文件，使用用户指定图片服务生成 28 张图并实现宣传站。随后已进入软件实施：四端原生工程通过 CI 构建，隔离的真实 IoT 网关与 Rust 执行端完成命令联动，macOS 原生窗口取得局部验证。完整产品用例目前为 `partial` 或 `not_run`，不能把局部检查等同全部验收；没有采购、制作或操作硬件。

文档检查为 Python 标准库程序。图形使用 Mermaid CLI 11.12.0 和本机浏览器导出，保留 `.mmd` 与 SVG。渲染工具来自已有本机缓存，记录实际工具版本；文档校验不依赖该缓存。源码与 SVG 的摘要关系由校验脚本检查，实际渲染与视觉审阅另行记录。

## 后续更新

更新参考结论时，定向重新读取受影响文件并产生新快照。原来源的检查日期不自动变成新日期。进入软件阶段后增加与具体 commit/工作树和制品绑定的运行记录，不将文档结果改名为 E2E 通过。

本轮不为远端链接做全量网络可达性检查，文件摘要也不是上游发布签名。当前快照是研究证据，不是可安装的 SDK 供应链锁。
