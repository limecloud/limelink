# 实现与验证边界

记录日期：2026-11-06。LimeLink 已从设计进入原生开发阶段。本文件描述当前代码；目标体验仍见 PRD。机器状态见 [status.json](status.json)，各需求的实现依据见 [implementation.json](implementation.json)。

## 当前交付

| 部件 | 实际代码 | 已取得证据 | 尚未证明 |
| --- | --- | --- | --- |
| 桌面执行端 | Rust、MQTT v5、SQLite 效果日志 | 10 组检查；真实 IoT HTTP/MQTT/mTLS 集成 | 长期运行、磁盘故障、性能与系统休眠 |
| macOS | SwiftUI 工作台、独立设备子进程、Keychain | release App 构建、临时签名；当前原生配对、卡片呈现回执、会话编辑与真实 Agent 设备确认 | 正式公证、安装更新回退、用户 HTTPS 界面全旅程 |
| iOS | SwiftUI 产品入口、系统安全存储、语音草稿 | GitHub Xcode 模拟器目标构建 | 真机、后台切网、商店签名 |
| Android | Compose、Keystore 加密存储、系统语音草稿、DNS-SD 网关发现入口 | Core 检查、16 组公告解析样例与调试 APK 构建 | NSD 系统生命周期、原生窗口、真机、正式签名 |
| Windows | WinUI 3、DPAPI、Rust 子进程、系统语音 | 产品 .NET Core 检查；WinUI 持续构建 | 目标窗口联调、安装更新回退与正式签名 |
| 本机网关部署 | 固定 Git 源码离线包、独立 Rust 辅助程序、macOS 安装与管理入口 | Linux ARM64 容器链路、原生安装/启停、设备证书与执行端 mTLS | 手机信任、Windows、正式签名、更新与完整失败恢复 |
| 远程普通部署 | Linux amd64 二进制、专用非 root systemd、Nginx 与原生安装引导 | Ubuntu 22.04 主机 17 项回环 HTTPS、登录、mTLS、私钥隔离和重启检查 | 公网 DNS/证书/安全组、完整远程客户端、其他架构、升级与卸载 |
| 宣传站与视觉 | Astro、响应式页面、28 张原图与跨端资源 | 网站独立构建/浏览器/HTTPS 验证及 Cloudflare 部署 | App 与硬件的产品验收 |

构建检查的源码摘要和范围保存在 [native-validation.json](evidence/native-validation.json)。[mTLS 集成记录](evidence/iot-runtime-mtls-integration.json)使用签名 Node 控制器和真实网关/运行时，批准及呈现由软件夹具驱动。[当前 macOS 卡片/会话记录](evidence/macos-native-ui.json)通过真实窗口配对、卡片呈现回执、电脑编辑/释放与软件手机接续查询。此前卡片可见但无回执，是因为中间偏好传递的滚动区域恒为零；现已直接读取外层几何区域并通过复验，[原失败记录](evidence/regression-2026-11-06.json)保留原因和修复结果。手机仍是测试程序。

## IoT 配合与依赖

平台固定提交为 `53f07b21d9fd0bb6c414e62496f10b8eb99aab25`，包含 Swift/Kotlin 显式空间 API、四平台原生云授权合同、通用 .NET 本地/云客户端及本地属性观测与回执补充。产品通过 [SDK 锁](../contracts/iot-sdk.lock.json)记录精确修订和 125 个消费文件摘要，`worktree_overlay=false`。导出工具默认读取固定 Git 对象，不消费来源目录中的未提交文件，不依赖相邻目录名称。

通用身份、模型、命令和文字服务归 IoT。本产品没有复制网关核心，也没有创建 `/link/*` 私有 HTTP 后台。产品协同通过 `action.invoke` 调用 [desktop.json](../contracts/desktop.json) 中的 `link.exchange`。设备 mTLS 身份与用户 Cookie 会话分离。

网关部署、设备入网/证书签发继续使用该修订的 IoT 管理流程。当前产品 App 接收管理员提供的设备配置；自主 CSR 入网向导、二维码配对和跨账号委派尚未实现。

本机开发部署已能生成当前电脑的独立设备配置，见[本机网关部署证据](evidence/local-gateway-installation.json)。构建工具从固定 Git 对象导出源码，拒绝不匹配的旧制品；离线包记录实际镜像 ID 和文件摘要。辅助程序只接受本机 Unix Docker Socket，以独立项目管理网关和 HTTPS 入口，初始化不自动启动服务或 Agent。首次登记当前电脑时，沿上游正式签发工具生成设备证书和 Topic ACL；用户会话、桌面设备和两类 CA 身份保持独立。

当前本机范围为 macOS 宿主与 Linux ARM64 镜像。隔离旅程验证 HTTPS 登录、匿名设备拒绝、真实桌面运行时 mTLS、空间和身份保持，以及包/Compose 篡改和远程 Docker 拒绝；命令行测试结束后清理容器网络并保留数据。随后补齐 macOS 图形入口，完成独立新目录安装、最终入口启停/状态恢复、执行端连接、Agent 默认关闭和内网/公网原生远程引导，见[窗口证据](evidence/gateway-management-macos-ui.json)。系统信任未修改。手机信任、Windows、完整中断恢复、卸载与正式更新仍待交付。

远程普通版本从相同固定 Git 对象构建原生 amd64/glibc 2.35 二进制，服务器不使用 Docker。用户授权主机已运行两个独立 `limelink` 用户 systemd 服务，真实 HTTPS、所有者 Cookie、设备 mTLS、私钥不可读和重启保留共 17 项检查通过，见[服务器证据](evidence/native-gateway-server.json)。当前服务与验收 TLS 入口仅绑定回环；公网域名尚无 DNS 解析，受信证书、安全组和完整外网/手机旅程未完成。安装器拒绝覆盖已有状态与服务，暂无更新、回退和卸载产品。

## 局域网网关发现

Apple 与 Android 的本地网关入口优先展示 `_limeiot._tcp.` 公告中的 HTTPS 地址，手动输入作为备用。Android 已接入系统 `NsdManager`，返回前台时开始发现，切换云入口或离开前台时停止；回调核对发现轮次，撤回的服务不会由迟到解析重新加入。候选按 origin 去重，列表保留明确选择，不自动登录或携带凭据探测。

Android 核心消费与 Apple 相同的 16 组公告样例，另检查无效 UTF-8、字节预算和显示名称边界；两项解析测试及 APK 构建通过，见[Android 发现证据](evidence/android-gateway-discovery.json)。本机尚未安装模拟器，官方 SDK 安装因许可未接受而跳过；Android NSD 的实际发现、撤回、前后台与窗口流程均未运行。构建不证明这些行为，TC-002 仍为部分验收。公告内容只提供候选，连接保持原有 HTTPS、证书校验和用户认证。

## 受限云核心与本轮 IoT 配合

IoT 已将原生授权平台扩展为 iOS/Android/macOS/Windows，并补齐 .NET 10 云客户端；没有另建产品身份或命令协议。上游 [阶段证据](https://github.com/limecloud/iot/blob/e01581888d8be168481b85242c5835864674df3e/docs/evidence/2026-11-05-native-desktop-cloud.json)记录 Go race/vet、18 组 .NET 检查、Swift/Kotlin 检查、7 项原生联合检查及独立 10 项网页检查。三种 SDK 的六个属性/动作旅程使用临时 MySQL、HTTPS/WSS、MQTT 模拟设备和浏览器明确批准，覆盖丢响应、控制面重启、同键恢复及子会话退出；不代表正式云提供方或目标系统 App 验收。

产品新增 Apple（供 macOS/iOS 共用）、Kotlin、.NET `CloudLinkClient`，直接消费固定 SDK。适配器核对当前主体、唯一有效网关、scope、设备页的绑定 revision 和当前模型；签名使用网关的 **local_space_id**，云空间只用于平台路由。产品身份按 origin、主体、云空间、网关、本地空间和设备隔离，避免换账号或重新绑定后复用旧签名身份。

恢复先读取当前主体所有空间中的原操作；未知/已尝试记录阻止换目标再次提交。查询不要求当前仍选中原空间或原设备仍在线；404 不补发。准备后取消保留未发送记录，SDK 仅允许明确放弃未发送或终态记录。动作只沿现有 `link.exchange` 模型进入同一本地命令账本。

[产品云核心证据](evidence/cloud-clients.json)来自三种真实库消费同一 HTTP 夹具，逐端独立验证本地空间签名、丢响应后重建客户端、原键 404 只查询、跨空间未知记录阻塞；.NET 另覆盖换主体/本地空间隔离、绑定变化、身份保存失败零提交、准备后取消和分页游标有界。本轮五类本机构建/回归和固定新修订的真实 HTTP/MQTT/mTLS 本地产品回归已通过。

四端工作台已新增本地/云入口切换、显式发起或恢复原生授权、授权码和同 origin 的系统浏览器入口。用户按服务端的 3 秒间隔明确查询一次授权结果，不运行后台自动批准或无限轮询。切换入口或账号清空旧投影；离开前台取消等待，迟到响应不能恢复旧目标。每次刷新只消费当前空间唯一有效网关，并在界面显示网关、本地空间和绑定修订。

云原操作列表读取当前主体全部空间的记录；用户明确查询原键或核对原 remote_id，不使用本地动作的短间隔自动 reconcile。已准备但未提交的记录可明确放弃；已尝试但结果未知的记录不可删除，并阻止换空间或电脑再次提交。旧操作仍可在未选目标时查询，其响应仅在主体、空间、网关、本地空间、绑定、设备及模型全部相同时更新当前编辑字段。

Apple 共用的实际工作台模型现有 8 组检查，覆盖授权间隔、原证明恢复与取消、空间网关选择、原操作恢复、未知阻塞、入口隔离、忽略取消的迟到响应和本地配对回执收尾，见 [本机检查](evidence/native-validation.json) 中 apple-workbench；这些专项采用传输夹具。[真实云工作台模型联调](evidence/cloud-workbench-ui.json)另使用临时 MySQL、HTTPS 控制面、WSS 网关和 MQTT/mTLS 产品终端，验证浏览器批准、配对、丢响应、控制面重启、原卡片仅一次提交和独立退出。该联调没有原生窗口或真手机。Android 已做 Core 检查与 APK 构建；Windows 云界面的行为旅程仍待目标系统验收。正式云提供方和完整跨网原生旅程尚未验收。云模型、ASR、媒体中继尚无产品转发能力；FR-021 继续保持部分完成。

## 正式的本地产品合同

设备模型 ID 为 `urn:limelink:model:desktop:1`，当前修订为 `sha256:8c8d0ddd4bbcb4e4463f16c27a8a60714c4e287da8621b4fddba672b6b44be65`。模型仅包含一个受限动作，无属性和事件。产品请求被平台命令账本包裹；原命令重复送达不重复创建卡片。

输入字段为 `client_id/public_key/kind/nonce/expires_at/payload/signature`。P-256 公钥为 65 字节 X9.63 小写十六进制，签名为 SHA-256 ECDSA 的 ASN.1 DER 十六进制。签名消息以 LF 连接下列字段，末尾无 LF：

```text
limelink.exchange/v1
space
device
model_revision
client_id
kind
nonce
expires_at（Unix 秒）
SHA256(payload UTF-8)（小写十六进制，无前缀）
```

请求有效期至多 30 秒；客户端默认 20 秒。客户端 UUID、nonce 和目标/模型/正文同时校验。载荷 JSON 最大 4096 字节，卡片/内容正文最多 2048 UTF-8 字节。原生 App 提交前保存完整原意图并回读；只允许一项未核实操作。超时和 404 保留记录，恢复只 GET 原键。

Apple、Android 与 Windows 本地工作台会自动收尾已核实成功的配对处理回执，用户可直接读取助手配置。收尾前再次查询原键，要求平台已确认且产品 `ok=true`；电脑上的配对批准仍独立进行。Android 和 .NET 各增加十一种结果检查，覆盖再次查询变为未知、错误类型、取消与存储失败；普通卡片不自动归档，云入口继续使用原操作列表。Android 已做 Core/APK 检查，Windows 已做 Core/C# 类型检查，目标窗口与系统生命周期仍待验收。

| kind | 当前行为 |
| --- | --- |
| pair/status | 同一 IoT 所有者会话下额外申请本机批准；120 秒窗口；公钥指纹核对 |
| card/cancel | 纯文本卡片，TTL 1～86400 秒；取消仅影响待展示卡片 |
| revoke | 撤销该客户端后续产品协同，停止其待展示卡片和写入租约 |
| session_create/claim/write/release | 单台电脑与创建该会话的客户端接续文本；CAS 修订和 30 秒写入租约 |
| content_put/remove | 带 SHA-256 和 TTL 的单项纯文本内容；当前不执行代码、加载任意 URL 或安装插件 |

SQLite 保存原回执、nonce 和效果意图，事务采用 WAL 与 `synchronous=FULL`。原回执上限 4096、客户端 16、卡片 256、会话/内容各 64，达到容量明确拒绝；当前不会自动清理账本重新接受重复命令。

`completion=submitted` 表示执行端已耐久提交产品结果，不能证明屏幕可见。桌面窗口活跃且卡片实际挂载后，私有本机通道才发送 `presented`。手机使用后续 `status` 读取当前展示状态；原命令回执保留最初事实，不改写历史。

## 隐私与保留的实际限制

工作台切换网关地址会清除候选凭据与旧连接投影，要求重新连接；切换空间或电脑会清除旧目标、指纹和会话/内容选择。草稿不因此自动发送。原任务保存在其原网关范围的安全存储中，重新连接后仍只查询原请求。Apple/Android 的待核实提示从实际持久记录恢复，预校验或保存失败不会凭按钮状态假定已经发送。

Windows 的呈现上报检查当前窗口活跃、卡片已布局并与滚动视口相交，滚动或重新激活时重新核对；这段代码仍需目标系统窗口验收，不能由构建通过证明屏幕效果。

手机和电脑的产品签名身份独立于 IoT 用户会话。设备证书仅在桌面执行子进程使用；不把 owner Token 写进配置。退出用户会话不会清除待核实请求，也不等于撤销设备证书。

协同正文到期后，主表与 `session_claim` 本机缓存回执在同一事务内清空正文，保留原命令、摘要、修订和防重放记录；重放原命令也先检查正文期限。SQLite 启用 `secure_delete` 并尝试截断 WAL，读者占用旧快照时保持清理待完成，释放后再次尝试。v1 普通启动要求明确迁移，旧缓存正文不能借同名新会话延长保留，旧空闲页整理状态可以跨重启恢复。[保留检查](evidence/content-retention.json)验证这些边界及活动数据库/WAL 的夹具正文扫描。

Agent 库已将正文、事件、设备范围、工具参数/结果和缓存回执的到期清理合并为事务，失败回滚；启用安全删除，旧文件重开安排空闲页整理，并与协同库共用 WAL 清理及读者占用后的重试。已过期正文不会被迟到消息重新写回；原运行、摘要、游标及防重放记录保留。20 项 Agent 检查包含这些边界，见[Agent 保留证据](evidence/agent-content-retention.json)。

客户端安全存储中的原意图、平台历史命令、Codex 会话、备份和系统快照仍有独立保留责任，本机两个数据库的清理不涵盖它们。历史引用容量回收、统一清除界面和完整保留/清除策略尚未完成，NFR-004 和 TC-023 继续保持部分完成。

诊断导出仅含版本、存储版本和计数，不含正文、身份、公钥、凭据或文件路径。诊断检查已验证此范围；它不证明所有运行日志都已通过隐私审计。

## 发布差距

首个 Codex Agent 适配器、三种客户端的独立动作/运行引用/原请求恢复，以及 macOS 本机批准和回复已有局部证据，详见[Agent 执行闭环](33-agent-execution.md)。默认关闭的设备工具已包括执行端范围/提案/结果保护与 Apple/Android/.NET 客户端代理。真实 Codex 经真实隔离网关读取独立模拟灯，确认后写入；设备与回传各丢响应后仅查询原意图，见 [Apple 实际工作台模型](evidence/agent-iot-apple-live.json)、[Android 实际核心](evidence/agent-iot-android-live.json)与 [.NET 实际核心](evidence/agent-iot-dotnet-live.json)。[macOS 窗口](evidence/agent-iot-macos-ui.json)另行完成设备选择、提交、本机批准和逐次写入确认；Android 当前只有 JVM 集成与 APK 构建。此轮使用回环 HTTP/MQTT 开发鉴权，没有实物或移动真机结论。

Windows 与 Android 助手源码已接入设备范围、逐次确认和两条原请求恢复；三种客户端均在意图保存后重新核对期限，延迟存储导致过期时零设备写入。Android 调试 APK 已构建；Windows 本轮在 macOS 上受 Windows 专用 XAML 编译器阻塞。四端原生完整旅程、完整 Agent 设备工具、云助手与本机安装仍未全面交付，不纳入已有卡片验证的通过范围。

macOS 设置页已提供本机 Agent 配置：兼容程序查找、工作目录、目录写入、超时和设备工具开关，以及断开、重新读取和保存重连。核心检查覆盖路径/预算、旧文档与外部修改拒绝、未知字段保护、设备身份保持和 `0600`；[设置窗口联调](evidence/agent-settings-macos-ui.json)从无 Agent 配置开始，真实完成保存重连与模型/模拟灯任务。

Windows 已补齐相同设置入口的源码、后台程序探测与保存重连；运行中禁止修改，断开后等待输出消费和进程退出，未退出时保留运行实例，关闭输入后拒绝后续写入。[Windows 设置检查](evidence/agent-settings-windows-core.json)记录 18 组 .NET 核心检查及 C# 类型检查；运行主机是 macOS，Windows ACL、XAML 构建、原生窗口和退出时序仍未验收。原始入网仍依赖管理员配置，本机网关安装器尚未完成。

当前三端无设备工具的 mTLS 协议夹具回归已通过；同路径真实模型整套回归多轮未通过，出现运行期限未知和严格回复不匹配，详见[当前失败记录](evidence/regression-2026-11-06.json)。这不覆盖或取消已单独通过的三端设备工具联调范围，也不能以旧整套记录替代当前失败。原因尚未确定，保留发布阻塞。

明确重配已提供四端确认入口：失效关系清除旧会话与内容，再由电脑批准新周期；原回执不变，正常配对不自动重启。完整跨网界面旅程、二维码、跨电脑会话迁移、网关 ASR/播放打断、通用内容包、自主设备入网、完整保留清除、原生更新回退、各端可访问性和性能仍需交付。系统语音识别仅生成草稿，不能记为网关 ASR。

未来硬件仍是另行立项的概念，当前没有固件、样机、BOM 或量产验证。任何 `v0.1.0` 放行必须按实际范围和 [发布门槛](20-release-and-operations.md)核验，不能仅凭源码齐备打“全部完成”标签。
