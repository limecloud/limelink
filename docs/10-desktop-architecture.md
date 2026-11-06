# 桌面端技术架构

参考 Shou 的“原生界面 → 本平台应用服务 → 小型能力接口 → 系统适配”，保留 macOS 和 Windows 各自的原生工程。平台执行核心继续在 LimeIoT，桌面端只实现自身产品用例与系统能力。

桌面首先是网关控制台，可连接本机或远程网关；Agent 的目标部署与客户端身份边界见[Agent 控制台与部署架构](32-agent-console-architecture.md)。接收内容只是其中一个协同功能，当前原生客户端构建不代表本机网关安装器已实现。

## 技术路线

| 平台 | 目标方案 | 已有可复用基础 | 待验证项 |
| --- | --- | --- | --- |
| macOS | Swift 6、SwiftUI、必要的 AppKit，建议 macOS 14+ | 上游 LimeIoTKit 已声明 macOS 14 支持；Shou 原生组织参考 | SDK 固定消费、登录、设备身份、后台、签名与权限 |
| Windows | WinUI 3、.NET 10、C# 应用/适配层 | Shou 的 Core/Platform/Presentation 分层参考 | 本产品 C# 平台客户端、设备通道、原生运行与发行 |

现已有根 SwiftPM、iOS Xcode、Windows Core/WinUI 工程，以及 Rust 桌面子进程。macOS 原生窗口已验证批准/呈现/会话编辑；其他目标的构建与窗口证据分别见[实现记录](29-implementation-and-verification.md)。

## 模块边界

| 模块 | 内容 |
| --- | --- |
| Presentation | 导航、选择、草稿、进度、可访问性、平台通知 |
| Application | 配对用例、目标核对、提交编排、路由冲突、恢复调度 |
| GatewayClient | 受控 HTTP、事件查询、完整原请求与回执核对 |
| DesktopRuntime | 设备会话、能力报告、有界命令接收与结果上报 |
| Platform | 系统安全存储、文件原子保存、进程生命周期、窗口显示与系统权限 |

UI 可以持有状态，但不决定动作授权、重试或证据真实性。平台接口按已实现能力拆分，不提前设计万能插件或任意命令执行器。

## 用户与执行身份

用户客户端使用用户会话读取工作台和发起请求。执行端持独立设备身份，仅接收当前绑定模型允许的动作；用户 Cookie、所有者 Bearer 与设备私钥分别存储。首个实现可同进程组装，但不共用授权对象或把“App 已启动”视为设备 ready。

后续需要关窗继续接收时，macOS 登录项与 Windows 后台进程分别实现。用户明确选择是否登录启动，正常退出行为可解释；卸载、退出用户和撤销设备分别处理，不留下隐形常驻服务。

## 首个本机动作

仅在本产品界面展示文本卡片。内容不作为脚本、HTML、命令行或任意 URL 执行。消息绑定原命令身份，窗口状态在正确 UI 线程观察；内容落盘与显示失败按原记录核实。

新增剪贴板、文件、快捷键或外部 Agent 功能时，以单个明确适配器和验收案例推进。Shou 的软件盘点代码、HachimoDock 的桌面输入路径不自动形成我们的兼容承诺。

首个 Codex App Server 适配器、macOS 助手与本机批准已接入，配置和实际验收见[Agent 执行闭环](33-agent-execution.md)。主机文件沙箱、模型运行和未来 IoT 设备工具拥有不同权限边界。

## 与手机的共享

Apple 平台优先复用版本明确的 LimeIoTKit 和通用产品值类型；AppKit、登录项和桌面权限留在 macOS 适配层。Windows 与 Android 共享 Schema 和测试向量，当前不为减少语言数量强行引入跨端 UI 引擎。

依据：[SRC-SHOU-ARCH、SRC-SHOU-BUILD、SRC-IOT-SWIFT](evidence/sources.json)。维护成本与四端测试投入见[风险](22-risks-and-open-decisions.md)。

## 桌面界面实现

桌面导航、Radix 主题、渐进展开和 3D 图标见[桌面界面与图标](brand/desktop-design.md)。macOS 专用 DesktopWorkspace 复用 WorkbenchModel，iOS 保留独立界面；Windows 将布局拆到 DesktopWorkspace.cs，原有授权与原请求策略仍由产品客户端负责。
