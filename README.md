# LimeLink · 柠联

通过网关连接手机、电脑与未来硬件终端的多端协同产品。桌面端提供工作台与明确授权的本机能力，手机端提供配对、输入、状态查看和任务跟进，LimeIoT 网关负责平台身份、命令与执行事实。

仓库：<https://github.com/limecloud/limelink>。

## 当前阶段

当前包含 macOS/iOS/Android/Windows 原生源码、Rust 桌面执行端、固定 IoT SDK、真实网关联调、[品牌与 28 张场景图](docs/brand/README.md)及 [site 宣传站](site/README.md)。macOS 本机窗口已验证批准、卡片展示与会话接续；各端构建、真机和正式发行分别取证。详见[实现与验证边界](docs/29-implementation-and-verification.md)、[构建试用](docs/30-build-and-local-trial.md)及[机器状态](docs/status.json)。

当前核心链路围绕同一局域网内的“电脑注册 → 手机选择电脑 → 发起有界任务 → 两端查看同一结果 → 断线后查询原任务”。远程访问、跨端会话接续、AI 语音和独立硬件按阶段推进。

## 文档

从[文档入口](docs/README.md)开始，建议依次阅读[需求基线](docs/00-product-baseline.md)、[产品需求](docs/02-prd.md)、[系统架构](docs/05-system-architecture.md)和[实施路线](docs/21-roadmap-and-status.md)。

Agent 入口为 [llms.txt](llms.txt) 与[文档目录](docs/catalog.json)。需求、测试计划和实际状态分别维护在 [requirements.json](docs/requirements.json)、[test-cases.json](docs/test-cases.json) 和 [status.json](docs/status.json)。

文档检查使用 Python 3.10+，不要求检出参考仓库、安装应用依赖或连接网关：

```sh
python3 "docs/scripts/verify_docs.py"
```

宣传站为 **https://link.limeai.run**，交付方式见[网站与部署](docs/28-website-and-deployment.md)。原创角色、跨端图标、VI、手机/电脑/网关场景与未来硬件见[完整图册](docs/brand/scene-gallery.md)。

## 工程关系

- [LimeIoT](https://github.com/limecloud/iot)：通用网关、设备、权限、命令、媒体与模型任务的事实源。
- 本仓库：LimeLink 的客户端体验、桌面能力适配、产品协同规则与联合验收。
- [Gootuan](https://github.com/limecloud/gootuan)：独立产品仓库及依赖边界的组织参考。
- Shou：macOS SwiftUI/AppKit、Windows WinUI 3/.NET 的原生分层参考，出处见[参考研究](docs/25-reference-research.md)。

当前不建立相邻目录依赖，不复制平台执行核心。SDK 已通过 contracts/iot-sdk.lock.json 固定上游 Git 修订与消费文件摘要。

## 许可

本仓库采用 [Apache-2.0](LICENSE)。第三方源码、字体、模型、内容与品牌适用各自许可；HachimoDock 仅作为设计研究来源，其当前许可证不授予本产品直接复用代码或素材的权利。
