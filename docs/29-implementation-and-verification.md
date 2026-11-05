# 实现与验证边界

记录日期：2026-11-05。LimeLink 已从设计进入原生开发阶段。本文件描述当前代码；目标体验仍见 PRD。机器状态见 [status.json](status.json)，各需求的实现依据见 [implementation.json](implementation.json)。

## 当前交付

| 部件 | 实际代码 | 已取得证据 | 尚未证明 |
| --- | --- | --- | --- |
| 桌面执行端 | Rust、MQTT v5、SQLite 效果日志 | 10 组检查；真实 IoT HTTP/MQTT/mTLS 集成 | 长期运行、磁盘故障、性能与系统休眠 |
| macOS | SwiftUI 工作台、独立设备子进程、Keychain | release App 构建、临时签名；真实窗口批准、卡片呈现和会话编辑 | 正式公证、安装更新回退、用户 HTTPS 界面全旅程 |
| iOS | SwiftUI 产品入口、系统安全存储、语音草稿 | GitHub Xcode 模拟器目标构建 | 真机、后台切网、商店签名 |
| Android | Compose、Keystore 加密存储、系统语音草稿 | Core 检查与调试 APK 构建 | 真机、完整界面旅程、正式签名 |
| Windows | WinUI 3、DPAPI、Rust 子进程、系统语音 | 产品 .NET Core 检查；WinUI 持续构建 | 目标窗口联调、安装更新回退与正式签名 |
| 宣传站与视觉 | Astro、响应式页面、28 张原图与跨端资源 | 网站独立构建/浏览器/HTTPS 验证及 Cloudflare 部署 | App 与硬件的产品验收 |

构建检查的源码摘要和范围保存在 [native-validation.json](evidence/native-validation.json)。[mTLS 集成记录](evidence/iot-runtime-mtls-integration.json)使用签名 Node 控制器和真实网关/运行时，批准及呈现由软件夹具驱动。[macOS 原生记录](evidence/macos-native-ui.json)另行通过实际窗口操作，手机仍是测试程序；没有把它记为真实手机验收。

## IoT 配合与依赖

平台补丁提交为 `313090d6b53e28d6e5ad1eaa28d29b8d7c479119`，包含 Swift/Kotlin 显式空间 API 及通用 .NET 本地客户端。产品通过 [SDK 锁](../contracts/iot-sdk.lock.json)记录精确修订和 123 个消费文件摘要，`worktree_overlay=false`。导出工具默认读取固定 Git 对象，不消费来源目录中的未提交文件，不依赖相邻目录名称。

通用身份、模型、命令和文字服务归 IoT。本产品没有复制网关核心，也没有创建 `/link/*` 私有 HTTP 后台。产品协同通过 `action.invoke` 调用 [desktop.json](../contracts/desktop.json) 中的 `link.exchange`。设备 mTLS 身份与用户 Cookie 会话分离。

网关部署、设备入网/证书签发继续使用该修订的 IoT 管理流程。当前产品 App 接收管理员提供的设备配置；自主 CSR 入网向导、二维码配对和跨账号委派尚未实现。

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

手机和电脑的产品签名身份独立于 IoT 用户会话。设备证书仅在桌面执行子进程使用；不把 owner Token 写进配置。退出用户会话不会清除待核实请求，也不等于撤销设备证书。

TTL 到期使产品表的当前正文不可见，并清空其正文列；这不等于 SQLite WAL、备份或网关历史命令中的物理擦除。`session_claim` 回执可能包含正文，输入原意图也可能含正文；这些记录尚无完整保留/清除策略。不要用真实敏感资料试用，NFR-004 和 TC-023 保持部分完成。

诊断导出仅含版本、存储版本和计数，不含正文、身份、公钥、凭据或文件路径。诊断检查已验证此范围；它不证明所有运行日志都已通过隐私审计。

## 发布差距

明确重配已提供四端确认入口：失效关系清除旧会话与内容，再由电脑批准新周期；原回执不变，正常配对不自动重启。受限云登录/跨网、二维码、跨电脑会话迁移、网关 ASR/播放打断、通用内容包、自主设备入网、完整保留清除、原生更新回退、各端可访问性和性能仍需交付。系统语音识别仅生成草稿，不能记为网关 ASR。

未来硬件仍是另行立项的概念，当前没有固件、样机、BOM 或量产验证。任何 `v0.1.0` 放行必须按实际范围和 [发布门槛](20-release-and-operations.md)核验，不能仅凭源码齐备打“全部完成”标签。
