# 首个 Agent 执行闭环

LimeLink 已接入 Codex App Server。客户端经 LimeIoT 网关向执行电脑提交任务，在该电脑明确批准后执行；运行引用、状态和回复可再次查询。控制台、网关和执行主机可以分开。

Apple、Android 与 .NET 客户端已接入 IoT 工具代理与逐次写入确认，完成真实 Codex、隔离网关和独立模拟设备的局部联调；macOS 已完成原生 Agent 窗口流程。设备工具默认关闭。Windows 目标构建与窗口、移动真机、其他 Agent、无人值守执行、云助手、语音任务与硬件反馈仍需分别验收或实现。已有“AI 整理”只生成草稿，与 Agent 执行入口分开。

## 当前范围

| 部件 | 实现与验收范围 |
| --- | --- |
| 设备合同 | 独立 `agent.exchange` 动作，风险 `high`；普通配对不直接执行任务 |
| Rust 执行端 | 本机批准、串行进程适配、运行/事件耐久记录、查询与中断；实验设备工具的范围、提案和结果记录 |
| macOS | 助手导航、执行电脑/目录/设备选择、任务提交、原任务查询与中断、本机批准、设备逐次确认和回复；设置页可配置本机 Codex、工作目录和设备工具并保存重连 |
| Apple 核心 | 当前动作检查、运行与设备范围持久化、工具代理、设备/回传原命令恢复、分页与目标隔离 |
| iOS | 共享模型和助手表单源码已接入；本机目标构建因缺少完整 Xcode 阻塞，未做真机验收 |
| Windows | Agent 产品核心、助手页、本机批准和本机助手设置源码已接入；18 组 Core 检查与 WinUI C# 类型检查通过，Windows ACL、完整构建及窗口仍需目标系统验证 |
| Android | 任务/设备选择、逐次确认/拒绝、原命令核实、分页回复与续接；Core、调试 APK 和真实网关模拟灯通过，尚未窗口或真机验收 |

平台回执 `confirmed` 和 `completion=submitted` 表示请求已被执行端处理。`agent.submit` 返回 `awaiting_approval` 时仍在等待批准，不代表 Agent 完成。

## 配置与使用

macOS 导入管理员提供的设备配置后，可在“设置 → 本机助手”断开执行端、启用 Codex、查找或选择程序、添加工作目录，按需开启目录写入和设备工具，再点击“保存并连接”。运行中表单禁用；断开会请求中断当前任务，进程退出后才能修改。设置只编辑 Agent 字段，保留原有设备身份、网关和证书路径。

Windows 已提供相同设置入口的源码：导入设备配置、选择原生 `.exe`、添加工作目录和权限、保存重连。程序查找在后台执行，并检查正式版本与 App Server 帮助；不通过 cmd 或 PowerShell 运行 npm 包装脚本。断开通过关闭输入请求中断，等待输出消费和进程退出；25 秒内未退出时保持不可编辑，并提示核实原任务。当前仅完成 macOS 上的 .NET 核心与 C# 类型检查，尚未完成 Windows 设置窗口、退出时序或 ACL 运行验收，见 [Windows 设置检查](evidence/agent-settings-windows-core.json)。

“自动查找”跳过低于当前适配基线 `0.166.0` 的版本，核对 App Server 帮助命令。最多探测 8 个不同程序，每个命令最多 2 秒、输出最多 16 KiB，在后台执行；这只是安装兼容性筛选，不代替实际任务验收。手动选择仍保留，LimeLink 不自动安装或升级 Codex。

管理员也可以在已有执行端配置中增加可选 `agent` 字段。以下是字段示例，需替换为执行主机上实际存在的绝对路径：

```json
{
  "agent": {
    "executable": "/opt/limelink/bin/codex",
    "workspaces": [
      { "id": "notes", "name": "笔记", "path": "/srv/limelink/notes", "allow_write": false }
    ],
    "timeout_seconds": 600
  }
}
```

1. 按现有 MQTT/mTLS 流程接入执行电脑并导入设备配置，控制台连接对应网关。
2. 请求配对，在执行电脑核对指纹并批准。配对与每次执行批准分开。Apple、Android 和 Windows 本地工作台会重新查询原命令，只收尾已确认且产品 `ok=true` 的配对处理回执，可直接读取助手配置；这不代表电脑已批准。丢响应、404、未知、平台失败或产品拒绝均保留原请求，仍须明确核实；普通卡片不自动归档，云入口继续使用原操作列表。Apple 已有原生窗口证据，Android 与 Windows 本轮分别通过核心/APK 和核心/C# 检查，尚未完成目标窗口验收。助手中的“核实原请求”只处理 Agent 请求。
3. 读取助手配置，选择工作目录、输入任务。默认只读；目录允许时才可选择修改文件。
4. 在执行电脑的助手页核对来源、原文、真实目录和权限，允许或拒绝。批准期限 120 秒，不能重复消费。
5. 选择原任务查询回复。成功运行可明确选择“继续所选对话”，服务端再次核对客户端、目录、沙箱与配置。

Android 将“助手”“协同”“网关”分开呈现，配对后在助手页读取执行电脑的目录。Windows 助手页通过独立控件同步当前空间和目标，不重复挂载同一个 WinUI 控件。本机批准只出现在实际执行电脑；手机和控制台查询不会替代批准。

macOS 和 Windows 将远程查询的忙碌状态与本机批准控件分开，网络查询期间仍可批准或中断本机任务。macOS 等待设备逐次确认时暂停后台查询；模型专项检查与真实窗口设备确认分别核对这一行为。

认证与模型配置由执行主机上的 Codex 管理。`managed_by_codex` 是认证归属，不表示模型一定可用。本轮 `login status` 曾报告未登录，但正式 App Server 调用仍完成真实任务，因此以实际调用结果判断。LimeLink 不读取、复制或上传隐藏凭据。

Agent 配置保存采用同目录原子替换；macOS 使用 `0600`，Windows 源码从创建临时文件时设置仅当前用户可访问、禁止继承的 ACL。配置必须是当前用户拥有的正规文件。保存前核对原文件未变化，拒绝符号链接或 ReparsePoint 配置入口和未知 Agent 字段，避免覆盖管理员修改或丢失未来字段。程序和目录要求存在的绝对路径，目录规范化后保存。Windows ACL 检查分支仍需在 Windows 运行，macOS 上执行的 .NET 检查不能替代它。

原始设备注册、证书签发与网关配置仍由管理员完成；Windows Agent 设置窗口尚未验收，macOS/Windows 本机网关安装管理尚未完成。新增动作会改变模型 revision，既有执行端须采用更新后的正式模型和匹配设备配置；数据库身份绑定 revision，不自动改写旧账本。

## 授权和工具

远端只提交配置中的目录 ID，不能指定任意路径、程序或参数。仅支持 `read-only` 与经配置允许的 `workspace-write`。派发前重新核对配对、配置摘要和目录；运行中撤销配对会请求中断。

**工作目录不是读取隔离边界。** 当前版本的只读沙箱可读取主机上的其他可读文件；允许写入时，内置主机工具的写入范围限定为该目录。批准界面明确展示这一点。模型连接仍需网络，`networkAccess=false` 限制的是沙箱工具网络访问。

适配器按有效配置关闭 MCP、Apps、插件、Web 搜索、多 Agent、生命周期 Hooks 与通知命令，不接受额外提权请求。无设备授权的任务不声明动态工具；实验工具仅接受下面两个显式入口。

Codex 仍拥有自己的配置、会话存储与提供方数据策略。LimeLink 批准不替代主机账户、文件权限或部署隔离。

## 设备工具与客户端确认（实验）

运行时与官方 App Server、Apple/Android/.NET 工具代理及 macOS 原生确认已联调。`agent.allow_iot_tools` 默认为 `false`，在执行端配置中明确设为 `true` 后，客户端才显示设备选择。当前设备验证采用独立身份的软件模拟灯，尚未验收实物或移动真机。

启用实验配置后，`agent.submit` 可包含 `iot_devices`，最多 4 个唯一设备 ID，不能包含执行电脑本身。范围与原任务一同耐久保存，电脑本机批准界面展示本次设备范围。继续对话必须保持完全相同的范围，不能通过 `thread/resume` 扩权。

| 动态工具 | 参数与行为 |
| --- | --- |
| `limeiot_read` | `device_id`；只读取本任务范围中的设备属性与可写标量 Schema |
| `limeiot_command` | `device_id`、`model_revision`、`path`、`value`；提出一次标量 `property.set`，后续由发起客户端逐次确认和派发 |

原任务客户端通过签名的 `agent.tool_capabilities` 读取开关，通过 `agent.tool_pending` 查询一条待处理提案，并以 `agent.tool_result` 回传核实后的结果。这些操作使用原 `agent.exchange` 动作；执行端不保存用户网关会话，也不接收模型指定的 URL 或凭据。客户端代理仍须使用 LimeIoT SDK 的当前模型、授权、原命令和真实回执，不能另建命令账本。

读取结果只接受设备、模型修订、在线状态和最多 8 个标量属性。属性包含路径、Schema、可写标识、值、观测时间和质量；没有观测时明确为空。写入结果必须匹配原设备、修订、路径和值，并携带原命令 ID 和状态；平台未提供观测时间时保持空值。该结果是原客户端签名、经产品客户端核实的陈述，不是执行端独立验证的网关加密证明。

运行时检查当前 thread/turn、工具名、范围、参数和结果预算，拒绝重复调用与冲突结果。写入结果未知、提案超时或取消时仍有未解决提案，均使任务保留 `unknown`，不能被随后到达的模型完成消息覆盖。重启不重新派发提案；已记录结果可按原内容幂等回传。

Apple、Android 与 .NET 的 `AgentIoTClient` 均与 UI 分开：先保存并回读范围与提案，范围内读取自动处理；写入必须在任务发起端点击“确认操作”。确认时重新查询提案、当前网关模型、在线状态与可写标量 Schema，并排除桌面模型。设备意图保存和回读成功后，在实际 POST 前再次核对提案期限；最多一次 POST，取消、存储失败、字段变化或过期均不能绕过此边界。延迟存储跨过提案期限的检查覆盖三种客户端，并核对零设备写入。

设备命令和结果回传各保存独立的原意图。丢失设备响应后只按原键查询，404 继续保留；设备成功但回传响应丢失时，也只查询原回传命令。即使通用原请求已归档，工具记录仍能核实原回传，不产生第二次设备操作或结果 POST。后续核实不能把已经回传的未知结果改写成成功。窗口中的“拒绝”不会创建任何设备命令。

Android 在前台按原运行查询，切换入口、目标或进入后台后清除旧工具投影，原记录保留在安全存储中。JVM 核心检查不能验证 Android 系统进程销毁、后台与密钥库行为；这些仍需目标系统验收。

Windows 现已消费平台修订 `53f07b2`，通过通用 .NET SDK 获取属性观测、创建 `property.set` 和核对 `device_result`，没有在产品中绕开平台协议。工作台源码提供设备选择、逐次确认/拒绝、原设备命令查询和结果回传恢复；失去前台时停止当前操作并清除工具投影。Core 与真实网关联调、C# 类型检查分别记录，尚无 WinUI 窗口或 Windows 安全存储生命周期验收。

## 状态与恢复

正常流程为 `awaiting_approval → approved → starting → running → succeeded/failed`；拒绝为 `rejected`，批准超时为 `expired`。执行前取消直接成为 `cancelled`。执行中先进入 `cancelling`，只有同一 thread/turn 的 `turn/completed(status=interrupted)` 才成为 `cancelled`。

| 情况 | 行为 |
| --- | --- |
| 提交响应丢失 | 保存原命令和运行引用，只查询原幂等键；404 不重建任务 |
| 平台结果未知 | 阻止新请求，保留待核实记录 |
| Codex 失联、输出超限或中断未确认 | 输入可能已送出时记录 `unknown`，不自动再跑 |
| 执行端重启 | `starting/running/cancelling` 转为 `unknown`，不自动恢复进程或重发输入 |
| 切换网关、空间或电脑 | 清除界面旧投影，保留原入口安全存储中的引用 |
| 退出执行端 | 请求中断并消费终态，超时保留未知；关闭进程不证明外部工具效果已撤销 |

会话 ID 与运行 ID 分开。新运行只能显式引用此产品此前成功的运行，不能列举或写入任意 Codex 历史。会话是否仍存在以实际 `thread/resume` 结果为准。

事件在每条 Agent 消息完成后入库，通过明确查询分页显示，尚非逐 token 流式输出或后台通知。工具仅显示类型，不转发命令原文、参数、隐藏推理或 stderr。

## 预算与保留

- 最多 8 个目录，输入最多 2048 UTF-8 字节，超时 30–1800 秒。
- 每次运行一个任务。最多 128 个运行、4096 条动作回执，容量达到后拒绝；尚无产品化归档回收。
- 最多 256 条事件，每条 400 UTF-8 字节，每页 4 条；单次回复最多 32768 字节，协议单行最多 128 KiB。
- 本机窗口展示最近 10 个文字分块，截断时提示；完整内容通过原任务分页查询。
- 每次运行最多 16 次设备工具调用，提案 120 秒截止；参数最多 1024 UTF-8 字节，标量最多 512 字节，结果最多 1600 字节。超出预算明确拒绝，不静默截断。
- 正文、事件和运行时缓存回执中的回复保留 1 小时；过期清空可见内容，引用与防重放记录保留。
- 三种客户端工具记录各最多 128 条；运行保留期届满后回收已解决记录。未核实的设备意图和结果回传继续保留，满额时拒绝新记录，不通过删除未知请求腾出空间。

设备范围、工具参数/结果及缓存提案同样在运行保留期届满后清空。Agent SQLite 从 v1 升级到 v2 增加工具表，隔离夹具验证旧队列保留与高版本拒绝；不是对真实用户数据库执行升级的验收。

任务正文、事件、工具范围/参数/结果及缓存回执在同一事务内清理；损坏回执使清理整体回滚，迟到消息不能把已过期正文重新写回。数据库启用安全删除，每次重开既有库都安排旧空闲页整理，再尝试截断 WAL；占用旧快照的读者释放后继续维护，`agent.content_cleanup_pending` 显示文件清理是否仍待完成。格式仍为 v2，原运行、摘要、游标及防重放记录保留，见[Agent 保留检查](evidence/agent-content-retention.json)。

端侧 TTL 与文件维护不清除网关命令正文/日志、客户端、Codex 会话或备份；活跃读者释放前仍可能读取旧快照，不构成物理擦除承诺。历史引用容量回收与完整保留/清理策略仍阻塞发布。

## 验证

复现时从仓库根目录运行，`--iot-root` 必须显式指定平台源码。隔离网关二进制通过 `LIMEIOT_TEST_TARGET_DIR` 指向已按固定上游修订构建的目录；不读取相邻仓库作为隐式依赖。

```sh
python3 "tools/verify-native.py" --checks runtime apple apple-agent apple-workbench macos
node "tools/test-iot-link.mjs" --iot-root "/absolute/path/to/iot" --mtls --agent
node "tools/test-iot-link.mjs" --iot-root "/absolute/path/to/iot" --mtls --agent --agent-executable "/absolute/path/to/codex"
node "tools/test-iot-link.mjs" --iot-root "/absolute/path/to/iot" --mtls --agent --apple-agent --agent-executable "/absolute/path/to/codex"
node "tools/test-iot-link.mjs" --iot-root "/absolute/path/to/iot" --mtls --agent --apple-agent --dotnet-agent "/absolute/path/to/dotnet" --android-agent
node "tools/test-macos-ui.mjs" --iot-root "/absolute/path/to/iot" --agent --agent-executable "/absolute/path/to/codex"
python3 "tools/test-agent-tools.py" --agent-executable "/absolute/path/to/codex"
node "tools/test-agent-iot.mjs" --iot-root "/absolute/path/to/iot"
node "tools/test-agent-iot.mjs" --iot-root "/absolute/path/to/iot" --agent-executable "/absolute/path/to/codex"
node "tools/test-agent-iot.mjs" --iot-root "/absolute/path/to/iot" --agent-executable "/absolute/path/to/codex" --native-ui
node "tools/test-agent-iot.mjs" --iot-root "/absolute/path/to/iot" --agent-executable "/absolute/path/to/codex" --native-ui --configure-agent
node "tools/test-agent-iot-android.mjs" --iot-root "/absolute/path/to/iot"
node "tools/test-agent-iot-android.mjs" --iot-root "/absolute/path/to/iot" --agent-executable "/absolute/path/to/codex"
node "tools/test-agent-iot-clients.mjs" --client dotnet --dotnet "/absolute/path/to/dotnet" --iot-root "/absolute/path/to/iot"
node "tools/test-agent-iot-clients.mjs" --client dotnet --dotnet "/absolute/path/to/dotnet" --iot-root "/absolute/path/to/iot" --agent-executable "/absolute/path/to/codex"
```

`--apple-agent` 额外运行真实 `WorkbenchModel → AgentClient → 网关 → 执行端`，核对回复、明确会话恢复和切换空间清除旧投影；批准由软件夹具驱动，界面未参与。原生检查需在窗口中完成配对与执行批准，结束后按脚本提示写入隔离完成标记，不把软件批准记为窗口验收。

`--dotnet-agent` 与 `--android-agent` 分别运行两端实际产品核心；Android 需配置进程级 JDK 21 和 Android SDK 路径。可同时附加 `--agent-executable` 使用真实 Codex。两端测试均核对两次运行共用明确的产品会话；测试凭据仅留在隔离进程与内存存储。批准仍由软件夹具驱动，不能算作 WinUI、Android 窗口或真手机验收。

三种客户端共用 [30 组协议样例](../contracts/fixtures/agent-responses.json)，覆盖正常/未知状态、目录批准标识、字段预算、重复/乱序事件、游标和越权沙箱；客户端还分别验证丢响应只查询原键、404 保留原请求、运行引用保存失败时零提交、当前动作缺失和跨空间拒绝。

[本地配对收尾专项](evidence/pairing-receipt-recovery.json)：Apple 工作台覆盖七种结果；Android 与 .NET 各覆盖十一种，额外核对再次查询变为未知、字符串 `"true"`、取消和存储失败。成功处理后可继续下一项任务，其他结果保留原意图并阻止新提交。Android 与 .NET 的无工具和设备工具网关旅程均使用同一收尾方法，不依赖手动归档。

[57 组设备工具样例](../contracts/fixtures/agent-tools.json)已由 Apple、Android 和 .NET 全量消费；Rust 消费参数和结果子集。它们覆盖范围、标量 UTF-8 预算、错误字段、Schema、重复属性、观测时间、回执目标与未知状态。三种客户端还单独检查保存/回读失败时零写入、保存期间过期、重复确认拒绝、两种丢响应恢复与 TTL 不丢失未知原意图；Android 与 .NET 另检查真正重叠的确认请求和未知结果后续核实不能改写原回传。

Rust 的 20 项 Agent 运行测试、8 项协议进程测试及 16 项协同回归通过，覆盖设备范围、跨客户端隔离、重复/冲突结果、取消/未知、TTL、协同正文和缓存清理、明确迁移、Agent 清理回滚与 WAL/旧空闲页、通道背压及工具请求预算；协同库清理详见[保留证据](evidence/content-retention.json)，其他客户端和构建的实际检查见[本机检查记录](evidence/native-validation.json)。

Windows 当前检查环境为 macOS。依赖已还原，但正式 WinUI 构建在 Windows 专用 `XamlCompiler.exe` 处退出 126；不将 .NET Core 通过标作 WinUI 构建通过。[工作台 C# 类型检查](evidence/windows-source-check.json)另行消费真实 SDK 引用，可用 `python3 tools/check-windows-sources.py --dotnet /absolute/path/to/dotnet` 复现；它不编译 XAML 及依赖 XAML 生成的 App 入口，不证明打包或窗口运行。Android 本轮已构建调试 APK，当前环境缺少 platform-tools，尚无安装与交互证据。

`python3 tools/verify-native.py --checks ios` 可单独检查 iOS 模拟器目标。本机仅有 Command Line Tools，`xcodebuild` 报告 `requires Xcode`；已将真实退出码 1 和环境阻塞写入检查记录，尚未进入 iOS 编译。macOS 的 SwiftPM 成功不能替代此目标检查。

- [网关与协议夹具](evidence/agent-gateway-integration.json)：真实 HTTP、MQTT/mTLS、批准、分页、会话恢复、中断确认；模型为夹具。
- [真实 Codex 无工具联调旧记录](evidence/agent-gateway-live.json)：保留原修订的通过范围。当前修订的三端整套复验未通过，先后出现 `.NET` 和 Apple 的 `agent_deadline_unknown`，另一轮续接回复多出句号；详见[当前失败记录](evidence/regression-2026-11-06.json)。定向检查失败会话的事件类型和时间后，确认 Apple 请求已进入轮次，但期限内没有助手回复，随后记录中断；未读取隐藏推理或凭据。该结果尚不能确定请求等待的原因。没有延长 60 秒运行期限或放宽严格回复断言，旧记录不作为当前整套通过依据。
- [真实 Codex 动态工具协议](evidence/agent-tools-protocol.json)：真实模型调用两个工具并恢复原会话；设备结果为合成夹具，没有连接真实网关或执行真实设备操作。
- [Apple 设备工具夹具](evidence/agent-iot-apple-integration.json)与[真实模型设备工具](evidence/agent-iot-apple-live.json)：实际工作台模型、真实隔离 HTTP/MQTT 网关与独立模拟灯；软件批准，设备响应和回传响应分别丢失后仍各一次 POST。不是原生窗口或实物验收。
- [Android 设备工具夹具](evidence/agent-iot-android-integration.json)与[真实模型设备工具](evidence/agent-iot-android-live.json)：实际 Kotlin 产品核心、相同的真实隔离网关与独立模拟灯；软件批准，两条原请求恢复分别仅一次 POST。运行于 JVM，没有 Android 工作台模型、窗口或真机验收结论。
- [.NET 设备工具夹具](evidence/agent-iot-dotnet-integration.json)与[真实模型设备工具](evidence/agent-iot-dotnet-live.json)：实际 .NET 产品核心、真实隔离网关与独立模拟灯；软件批准，两条丢响应恢复分别只查询原键。不是 WinUI 窗口、Windows 主机或实物验收。
- [macOS 原生设备工具](evidence/agent-iot-macos-ui.json)与[原生助手记录](evidence/macos-agent-ui.json)：同一轮真实窗口登录开发网关、配对、选择设备、提交、批准和逐次写入确认，最终显示设备确认与模型回复。此轮为回环 HTTP/MQTT 鉴权开发链路，`device_mtls=false`，不能继承前述 mTLS 测试的范围。
- [macOS Agent 设置与真实任务](evidence/agent-settings-macos-ui.json)：初始设备配置没有 Agent，经设置窗口启用、选择程序/目录及设备工具、保存并连接，再完成上述真实任务。脚本核对设备配置其他字段未变、权限 `0600`、确认前零写入与确认后唯一写入；[设置界面截图](evidence/screenshots/agent-settings-native.png)保留本轮自动选中 Codex `0.166.0` 的界面，[任务结果截图](evidence/screenshots/agent-settings-task-result.png)保留设备确认和成功回复。
- [Windows Agent 设置核心与源码检查](evidence/agent-settings-windows-core.json)：18 组 .NET 检查覆盖配置身份保持、外部修改保护、路径、预算与有界程序探测；WinUI C# 类型检查另行通过。Windows ACL、XAML 编译、原生设置窗口与退出时序未验收。
- [批准界面](evidence/screenshots/agent-native-approval.png)与[设备确认界面](evidence/screenshots/agent-native-device-confirmation.png)保留较早一轮实际窗口截图。当前构建重新完成配对后直接读取配置、本机批准、设备确认和最终回复，验收以绑定源码与二进制摘要的当前记录为准。

`--native-ui` 需要先构建 macOS App，在窗口完成连接、配对和任务填写；就绪后向 `.dev/agent-iot-native-ready` 写入 `ready`，再提交任务，避免把手动准备时间算入运行观察期限。脚本会在提案到达时核对零写入，操作后核对唯一设备命令、最终属性和运行回复。截图完成后按提示向隔离完成标记写入 `done` 关闭测试应用。两个身份分别是执行电脑 `device-lamp` 与模拟灯 `device-button`；名称沿用平台测试夹具，不代表其产品类别。此验证没有实体手机，也没有验收 iOS 后台、实物硬件或完整跨网。

协议依据 [OpenAI Docs App Server](https://developers.openai.com/codex/app-server/)、[配置参考](https://developers.openai.com/codex/config-reference/)与已安装 `codex-cli 0.166.0` 导出的 Schema，[版本记录](evidence/agent-reference.json)保存接口依据；新版的额外读取限制不视作当前支持。

实现复用 `LinkClient` 的命令恢复与安全存储，协议适配独立于界面。平台身份、物模型、授权与命令事实继续由 LimeIoT 拥有。
