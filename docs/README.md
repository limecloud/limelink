# LimeLink 文档中心

文档基线日期：2026-11-05。读者为产品、客户端、网关集成、测试及交付人员。当前包含设计基线、原生客户端与运行时、视觉和宣传站。软件验证按范围记录，硬件仍未立项；先读[实现与验证边界](29-implementation-and-verification.md)和[构建试用](30-build-and-local-trial.md)。

## 产品范围

LimeLink 由电脑桌面软件、手机端和 LimeIoT 网关协作。手机通过网关选择已授权的电脑并跟进任务；桌面软件提供原生工作台及有限本机能力。未来硬件可作为独立终端加入，当前不依赖 Gootuan 产品，也不开始硬件开发。

“配对”包括用户登录、网关归属、电脑执行端接入和产品协同关系四种不同操作；同一账号登录不自动允许远程执行。网关负责平台命令事实，本机执行端负责可验证的本机效果，界面只呈现已核实的结果。

## 阅读路径

| 角色 | 建议顺序 |
| --- | --- |
| 产品与决策 | 00 → 01 → 02 → 03 → 21 → 22 |
| 架构与平台 | 05 → 06 → 07 → 08 → 09 → 12 → 27 |
| 桌面与手机 | 04 → 10 → 11 → 15 → 17 → 18 |
| 测试与交付 | 02 → 16 → 19 → 20 → requirements.json → test-cases.json |
| 后续扩展 | 13 → 14 → 23 → 24 → 25 |
| 视觉与宣传 | [品牌入口](brand/README.md) → [28 张图册](brand/scene-gallery.md) → [VI](brand/vi-spec.md) → 28 |

数字对应下表编号，不是版本号。

## 文档导航

| 编号 | 文档 | 主要内容 |
| --- | --- | --- |
| 00 | [需求基线](00-product-baseline.md) | 已确认方向、假设、排除项 |
| 01 | [产品定位与场景](01-positioning-and-scenarios.md) | 用户价值、替代方案与验证 |
| 02 | [产品需求 PRD](02-prd.md) | 功能边界、优先级、成功条件 |
| 03 | [用户旅程](03-user-journeys.md) | 配对、协同、取消与恢复 |
| 04 | [信息架构与交互](04-information-architecture-ux.md) | 桌面/手机任务与状态反馈 |
| 05 | [系统架构](05-system-architecture.md) | 部件、部署与职责 |
| 06 | [领域对象与数据](06-domain-model-data.md) | 身份、绑定、任务、事实源 |
| 07 | [配对与授权](07-pairing-and-authorization.md) | 各类配对、撤销与竞争 |
| 08 | [跨端会话与协同](08-cross-device-sessions.md) | 路由、接续与输入权限 |
| 09 | [任务与故障恢复](09-tasks-and-recovery.md) | 幂等、回执、未知与取消 |
| 10 | [桌面技术架构](10-desktop-architecture.md) | SwiftUI/AppKit、WinUI 3、执行适配 |
| 11 | [手机技术架构](11-mobile-architecture.md) | SwiftUI、Compose、系统生命周期 |
| 12 | [LimeIoT 接入](12-gateway-integration.md) | 可复用能力、缺口与上游协作 |
| 13 | [AI 与语音](13-ai-and-voice.md) | 输入、生成、授权和播放 |
| 14 | [内容与组件](14-content-and-widgets.md) | 有界内容、数据新鲜度与安装 |
| 15 | [安全与隐私](15-security-and-privacy.md) | 信任、凭据、最小数据与威胁 |
| 16 | [可靠性与性能](16-reliability-and-performance.md) | 断连、背压和测量计划 |
| 17 | [仓库与工程规范](17-monorepo-engineering.md) | 产品边界、依赖与构建 |
| 18 | [开发与集成路线](18-development-and-integration.md) | 文档检查、后续最小实现 |
| 19 | [测试与验收](19-testing-and-acceptance.md) | 层级、用例、证据与放行 |
| 20 | [发布与运维](20-release-and-operations.md) | 原生交付、兼容、回退与支持 |
| 21 | [路线图与状态](21-roadmap-and-status.md) | 阶段出口、依赖与现状 |
| 22 | [风险与未决事项](22-risks-and-open-decisions.md) | 风险责任、阻塞与决策触发 |
| 23 | [未来硬件终端](23-hardware-terminal-roadmap.md) | 路线比较与立项门槛 |
| 24 | [品牌、国际化与许可](24-brand-localization-and-licensing.md) | 命名、资源、内容与商业边界 |
| 25 | [参考项目研究](25-reference-research.md) | IoT/Gootuan/Shou/HachimoDock 借鉴 |
| 26 | [术语表](26-glossary.md) | 避免身份、状态和完成范围混淆 |
| 27 | [架构决策记录](27-architecture-decisions.md) | 决策、理由与重新评估条件 |
| 28 | [宣传站与部署](28-website-and-deployment.md) | 静态站、资源复用、Cloudflare 与独立验收 |
| 29 | [实现与验证边界](29-implementation-and-verification.md) | 当前代码、实际合同、证据与缺口 |
| 30 | [构建与隔离试用](30-build-and-local-trial.md) | 固定 SDK、四端构建与联合检查 |
| 视觉 | [品牌与场景图册](brand/README.md) | Logo、角色、跨端图标、VI 与未来硬件场景 |
| 证据 | [来源与证据边界](evidence/README.md) | 来源快照、检查方法及不能证明的事 |
| 覆盖 | [覆盖与待核验问题](evidence/coverage.md) | 完整性、知识维度与资料缺口 |

## 机器索引与维护

[catalog.json](catalog.json)只管理文档导航；[requirements.json](requirements.json)是需求清单；[test-cases.json](test-cases.json)是验收计划；[status.json](status.json)记录真实实现状态；[来源台账](evidence/sources.json)与[上游快照](evidence/upstream-snapshot.json)绑定参考内容。它们均不授予运行权限。

本地相对链接必须在本仓库内解析。参考工程使用来源台账中的仓库地址和路径，文档检查不访问相邻检出。执行 `python3 "docs/scripts/verify_docs.py"` 检查导航、链接、图源摘要和追踪关系，检查结果写入[文档验证记录](evidence/documentation-verification.json)。
