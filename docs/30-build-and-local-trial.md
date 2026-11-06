# 构建与隔离试用

Agent 的可选运行配置、权限、复现命令与当前限制见[首个 Agent 执行闭环](33-agent-execution.md)。

当前制品用于开发验证，支持范围以 [实现记录](29-implementation-and-verification.md)为准。不要把调试包、临时签名或模拟器制品当作商店发行版。

## 固定 IoT SDK

从仓库根执行，使用公开 IoT 仓库或一个显式指定的本地来源。Git 工作树可以有其他改动，默认导出只读取锁定提交。

```sh
mkdir -p ".dev"
git clone "https://github.com/limecloud/iot.git" ".dev/iot-source"
python3 "tools/prepare-sdk.py" --source ".dev/iot-source"
```

升级依赖需显式传入 `--revision <完整提交>` 与 `--update-lock`，审核 lock 后重新构建消费者。`--accept-worktree --update-lock` 仅用于开发快照，不能用于发布。

## 原生构建

| 平台 | 工具 | 命令 |
| --- | --- | --- |
| macOS | Swift 6、Rust/Cargo、系统签名工具 | `python3 tools/package-macos.py` |
| iOS | 完整 Xcode、iOS 17+ SDK | 打开 `apps/ios/LimeLink.xcodeproj`；开发构建选择模拟器或自己的签名团队 |
| Android | JDK 21、Android SDK 36、Build Tools 36.0.0 | 在 `apps/android` 执行 `sh gradlew :core:test :app:assembleDebug` |
| Windows x64 | Windows、.NET 10、MSVC/Rust | PowerShell 执行 `tools/package-windows.ps1` |

macOS 产物位于 `.dev/artifacts/LimeLink.app`，使用 ad-hoc 签名，没有 Developer ID 公证。Android 调试 APK 位于 `apps/android/app/build/outputs/apk/debug/`。Windows 打包脚本包含 Rust 执行端，产出开发 ZIP。各端 CI 见 [native.yml](../.github/workflows/native.yml)，iOS 使用 unsigned simulator build，不自动创建 App Store 包。

`tools/verify-native.py --checks runtime apple macos ios android dotnet` 按指定项执行并记录真实退出码/源码摘要。缺失工具需通过 `--gradle`、`--dotnet` 和进程级 `JAVA_HOME/ANDROID_HOME` 指定；不修改系统全局配置，也不自动接受本机 SDK 许可。iOS 需要完整 Xcode，本机只有 Command Line Tools，此目标当前因环境阻塞，未进入编译。跳过项不记为通过。

## 本机网关开发部署

当前本机方案支持 macOS 宿主已有的 Docker 引擎与 Linux ARM64 开发镜像。构建需要 Python 3.12+、Git 和可用的 Docker 构建环境；安装辅助程序不依赖宿主 Python，而是在隔离容器内运行固定上游管理工具。缺少 Docker 时不自动安装，远程 Docker 引擎被拒绝。macOS 图形入口已接入；Windows 和正式发行仍待交付。远程 Linux 使用下方的普通原生版本。

macOS 在“网关 → 安装与管理”或“设置 → 网关”管理同一安装。自动发现 Docker 与 Compose；选择离线包、新安装目录、私网或回环地址和端口，明确安装、启动，再按需连接桌面执行端。安装不自动启动服务或启用 Agent，失败保留原目录，刷新核实原状态。当前原生窗口、停止重启、执行端连接和远程引导见[窗口证据](evidence/gateway-management-macos-ui.json)。

构建开发 App 时可显式附带离线包，界面将自动校验并使用它；未附带时由用户选择目录。已包含离线包的旧构建需要继续显式指定包，构建器不会静默沿用旧制品：

```sh
python3 "tools/package-macos.py" --gateway-bundle ".dev/gateway-bundle-arm64"
```

从显式上游 Git 来源构建，读取 SDK 锁定提交，忽略来源工作树的其他改动：

```sh
python3 "tools/package-gateway.py" --source "/path/to/iot" \
  --platform linux/arm64 --output ".dev/gateway-bundle-arm64"
cargo build --manifest-path "runtime/Cargo.toml" --locked --bins
```

已有上游 NAS 制品时可以传入 `--artifacts /path/to/artifacts`，必须与固定提交的完整构建输入一致。`--runtime-base` 仅复用通过上游运行层前缀校验的本地依赖镜像，仍重新组装当前制品，不能拿旧镜像补写新提交标签。本轮 Docker 虚拟机 DNS 无法访问镜像仓库，因此从固定 Git 源码重新交叉构建当前制品，再复用已校验依赖层完成离线包；原失败与实际通过范围见[证据](evidence/local-gateway-installation.json)。构建输出为未签名开发目录，拒绝覆盖已有包。

安装到不存在的目录，端口须未占用。以下地址仅供本机试用；手机需要使用这台电脑可达的私网 IPv4：

```sh
"runtime/target/debug/limelink-gateway" initialize \
  --bundle ".dev/gateway-bundle-arm64" --directory ".dev/local-gateway" \
  --docker "/path/to/docker" --compose "/path/to/docker-compose" \
  --host 127.0.0.1 --https-port 18443 --mqtt-port 18883
"runtime/target/debug/limelink-gateway" start \
  --directory ".dev/local-gateway" --docker "/path/to/docker" --compose "/path/to/docker-compose"
```

`--compose` 指向独立 Compose 程序；使用 Docker 自带插件时省略它。初始化先核对包与实际镜像，创建独立空间、为当前电脑准备正式设备证书和执行端配置；不自动连接执行端或启用 Agent。返回的 `runtime_configuration` 可在现有管理员配置入口导入。所有者登录凭据保存在安装目录 `state/secrets/owner-token`，设备配置为 `desktop-runtime.json`，两者不可互用。

`status` 和 `stop` 沿用 `start` 的目录及工具参数。停止保留空间、数据库、证书和原请求；再次 `start` 使用原目录，不重新初始化。启动后由 Docker 托管，关闭辅助程序不会停止网关。服务状态不代表 HTTPS 用户登录或 Agent 任务成功。当前没有自动重建、更新、卸载、故障清空或全局证书信任操作。

使用原生客户端前仍需按目标系统流程核对并信任安装的 HTTPS CA；本轮仅在隔离检查进程内信任测试 CA，未验收系统/手机信任引导，也不关闭证书校验。可复验实际新目录安装与恢复：

```sh
python3 "tools/test-local-gateway.py" --bundle ".dev/gateway-bundle-arm64" \
  --helper "runtime/target/debug/limelink-gateway" --runtime "runtime/target/debug/limelink-runtime" \
  --docker "/path/to/docker" --compose "/path/to/docker-compose" \
  --output ".dev/local-gateway-installation-result.json"
```

该命令只操作独立临时 Compose 项目，结束后移除其容器和网络，保留测试数据。命令本身证明辅助程序与真实容器链路；原生窗口另见上面的独立证据，手机、正式签名和更新回退仍未验收。

## 远程 Linux 普通版本

普通版本直接运行 Linux 二进制、Mosquitto、Nginx 与 systemd，服务器不使用 Docker，也不需要 Rust 或 Node.js。当前开发包面向 amd64、glibc 2.35+；实际验收主机为 Ubuntu 22.04，不能据此声明其他发行版已支持。构建使用明确的上游 Git 来源，完整输入须匹配固定提交；网页制品经过上游完整校验，Rust 重新构建到指定 glibc 基线：

```sh
python3 "tools/package-native-gateway.py" --source "/path/to/iot" \
  --build-source "/path/to/verified-source-export" \
  --home-artifacts "/path/to/verified-home-artifacts" \
  --toolchain-cache ".dev/native-toolchain" --output ".dev/native-gateway-amd64"
```

`--build-source` 可省略，届时在固定 Git 导出中编译。输出目录与 `.tar.gz` 是未签名开发制品，包含文件摘要、上游提交和构建来源；拒绝覆盖已有目录。App 的“远程”引导填写公网域名或内网 IPv4、独立 SSH 地址、用户名、端口、远程准备目录和本机原生安装包，可导出 Markdown。此入口生成步骤和 HTTPS 地址，不自动建立 SSH 会话，也不把引导生成记为部署完成。

将归档通过已核验 SSH 通道上传，核对摘要并安全解压。远程管理员先准备 Python 3、OpenSSL、Mosquitto、Nginx 和 systemd；安装器不更新系统或自动安装依赖。在包目录执行：

```sh
python3 -B "install.py" inspect
sudo python3 -B "install.py" install --origin "https://gateway.example.com" \
  --mqtt-port 8883 --mqtt-bind 127.0.0.1
sudo systemctl enable --now limelink-broker.service limelink-gateway.service
sudo systemctl status limelink-broker.service limelink-gateway.service --no-pager
```

SSH 可以使用 root 或具有 sudo 权限的管理员，两个服务始终使用专用 `limelink` 账号。程序位于 `/opt/limelink/releases/`，数据与身份位于 `/var/lib/limelink`；已有目录或同名服务不被覆盖。HTTP `17880` 和明文 MQTT `18884` 只绑定回环地址。设备端口须强制验证独立客户端证书；示例先只监听回环，按批准的网络范围开放前需核对防火墙和安全组。服务的 systemd 挂载隔离禁止读取两类 CA 私钥和桌面设备私钥。

HTTPS 由独立 Nginx 站点接入，保留原始 Host。内网使用网关 CA 并在访问端明确安装信任；公网使用覆盖域名的受信证书。DNS、TLS 和主机/云防火墙分别核对，不把内部 HTTP 或明文 MQTT 映射到公网。宣传站与网关使用不同域名，已有站点在 `nginx -t` 通过后通过 reload 接入。

本轮已在用户授权服务器完成原生安装、systemd、回环 HTTPS 登录、mTLS、匿名拒绝、私钥隔离和重启保留的 17 项检查，见[服务器证据](evidence/native-gateway-server.json)。后续已接通 `https://gateway.link.limeai.run`，公开 HTTPS 登录、设备证书认证与实际桌面运行时上线通过，见[公网证据](evidence/public-native-gateway.json)。HTTP 80 用于证书验证/续期，TCP 443 用于用户端，TCP 8883 用于设备 mTLS；用户须同时在云安全组与宝塔/系统防火墙放行。此次 UFW 新增 8883，443/80 原已放行，外网均已实际可达。完整手机旅程仍未验收。可在管理员准备好相同回环 TLS 验收入口后运行：

```sh
sudo python3 "tools/test-native-gateway.py" --state "/var/lib/limelink" \
  --tls-port 18443 --restart --output "/var/tmp/limelink-native-verification.json"
```

`--restart` 明确重启这两个服务，检查原空间和身份保持。停止时使用 `systemctl stop limelink-gateway.service limelink-broker.service`，保留数据。正式签名、升级、回退、中断恢复与卸载仍未实现。

## 设备配置

先按锁定 IoT 修订的正式设备接入流程安装模型、注册设备、签发 mTLS 证书并配置 Broker ACL。以下仅是执行端配置形状；占位符必须替换为管理员实际配置。

```json
{
  "mqtt_host": "gateway.example",
  "mqtt_port": 8883,
  "space": "your-space",
  "device": "your-desktop",
  "model_revision": "sha256:8c8d0ddd4bbcb4e4463f16c27a8a60714c4e287da8621b4fddba672b6b44be65",
  "database": "state/limelink.sqlite",
  "ca": "certs/ca.crt",
  "certificate": "certs/device.crt",
  "private_key": "certs/device.key"
}
```

配置及证书路径目前由文件位置之外的进程工作目录解释；正式使用请填写本机绝对路径，不要直接使用本例相对路径。设备配置与私钥只保存在本机用户控制的目录中。生产运行要求 mTLS；仅显式开启 `allow_loopback_development` 且地址严格为 `127.0.0.1` 才接受测试密码。

桌面“协同 → 接收 → 管理员配置”选择设备配置并启动。Apple 与 Android 客户端优先发现同一网络中的网关（NAS 需启用上游公告器），手动 HTTPS 地址保留为备用。Android 在“网关”页选择发现的地址，再连接自己的所有者会话；未发现时可以重新查找或展开手动地址。随后明确选择空间与电脑并请求配对，在电脑核对名称/指纹后批准。该流程要求两端属于同一 IoT 所有者，不是跨账号分享。

Android `GatewayCandidateTest` 包含 16 组共享公告样例及 UTF-8/字节预算/显示名称边界。上述 `:core:test :app:assembleDebug` 会执行解析检查并构建系统 NSD 适配器，但不会运行 Android 服务发现或窗口。[本轮记录](evidence/android-gateway-discovery.json)单独列出未验收项。模拟器需要另行安装 ADB、Emulator 和系统镜像并接受官方 SDK 许可；本机安装尝试因许可尚未接受而跳过，不能将 SDK Manager 的零退出码当作安装成功。窗口联调需使用实际 HTTPS 入口与测试设备信任的证书，不能向正式 App 传入 HTTP 夹具或关闭证书校验。

macOS 也可在“设置 → 本机助手”导入相同设备配置。断开后可启用 Codex、自动查找兼容程序、选择目录与权限并保存重连；这不会注册新设备、签发证书或安装网关。详细步骤与限制见[Agent 配置](33-agent-execution.md#配置与使用)。

Windows 的“设置 → 本机助手”已实现对应源码，选择程序只接受原生 `.exe`。本轮 .NET 18 组核心检查与 WinUI C# 类型检查在 macOS 通过；Windows 文件 ACL、完整构建及设置窗口需在目标系统执行，[记录](evidence/agent-settings-windows-core.json)未将这些项目标为通过。

发送后先查询原请求并完成已核实记录，再发起下一项动作。卡片受理与实际展示分别看待；会话编辑前取得 30 秒输入资格。冲突后重新读取，不擅自覆盖对方内容。

## 隔离联合检查

准备 Rust 编译的 `limeiot-gateway`、`limeiot-model-validator`、`limeiot-simulator` 及 Mosquitto。通过进程环境显式设置 `LIMEIOT_TEST_TARGET_DIR` 与 `LIMEIOT_MOSQUITTO`，不在脚本中隐式寻找相邻仓库。

```sh
cargo test --manifest-path "runtime/Cargo.toml" --locked
cargo build --manifest-path ".dev/iot-source/Cargo.toml" --locked --bin limeiot-gateway --bin limeiot-model-validator --bin limeiot-simulator
node "tools/test-iot-link.mjs" --iot-root ".dev/iot-source" --mtls
```

测试自动创建本仓库 `.dev/` 下的独立临时空间、数据库、凭据和短期 CA，使用本机回环端口，不接触现有家庭或生产网关。mTLS 检查通过不代表 HTTPS 用户界面或真机验证通过。

macOS 可另运行 `tools/test-macos-ui.mjs --iot-root .dev/iot-source`，通过真正窗口批准并编辑测试会话；手机仍是软件夹具。测试提示在 `.dev/macos-ui-progress.json`；打开“协同 → 接收”后先向 `.dev/macos-ui-ready` 写入 `ready`，再由测试程序发起有期限的配对。操作完成后写入 `.dev/macos-ui-finish` 内容 `done` 关闭隔离栈。脚本不会替你通过本机私有 stdin 批准。

## 产品云核心检查

固定 SDK 后运行 `node tools/test-cloud-clients.mjs`，需要 Swift、JDK 21 和 .NET 10；通过 `--dotnet <可执行文件路径>` 指定 .NET。可以用 `--platform apple`、`--platform android` 或 `--platform dotnet` 单独验证，Android 仍使用进程级 JAVA_HOME/ANDROID_HOME。

脚本先核对导出的 SDK 与 lock，再启动独立的回环 HTTP 夹具。它验证真实产品库的本地空间签名、原请求恢复、404 不重发及跨空间阻塞；输出 `.dev/cloud-clients-*.json`，含输入摘要和明确的 fixture/native_app/hardware 边界。常规 Android Core 检查未启动夹具时会跳过这条专项，用脚本运行才实际验收它。CI 三个宿主 job 均执行对应专项；iOS 另做模拟器编译。

实际 IoT 云协议的 HTTPS/WSS/MQTT 联调仍由固定上游 `tools/test-control.mjs --native-clients` 执行；显式提供 LIMEIOT_DOTNET 可加入 .NET 属性/动作旅程，需先按上游说明构建运行时与 Console/Admin。网页专项 `--control-web` 分开使用独立临时数据库，避免合并旅程累计超过正式每账号 16 空间上限。上述库联调与工作台界面验收分别记录，不能由库检查推定完整跨网界面旅程通过。

## 云工作台试用与恢复

在工作台选择云控制面，输入精确 HTTPS origin。可以恢复既有会话，或明确点击“发起 / 恢复授权”：界面显示授权码，系统浏览器只打开 SDK 核对过的同 origin 授权地址。在浏览器核对平台、授权码和账号后批准，回到应用按间隔明确查询结果。离开前台会停止当前等待；如授权提示已清空，点击恢复云会话，或恢复原授权后查询，不会自动另建授权。

登录后明确选择云空间并刷新唯一有效网关与电脑。核对网关、本地空间、绑定修订、电脑及指纹后再申请本机配对；桌面执行端仍须由电脑用户明确批准。云操作只支持现有受限动作，模型草稿继续使用本地网关入口。

响应丢失时在“当前账号全部空间的原操作”选择原记录，查询原请求或明确核对原网关回执。无需重新选择原设备，也不能重发；结果未知会阻止新的提交。完成终态记录或放弃尚未提交的准备记录必须明确点击，未知记录由 SDK 拒绝清除。

`swift run -j 4 WorkbenchChecks` 验证 Apple 实际工作台模型的 8 组授权、路由、恢复、生命周期和本地配对收尾行为；`python3 tools/verify-native.py --checks apple-workbench` 记录源文件摘要。配对专项包含已确认、延迟确认、产品拒绝、未知、平台失败、丢响应和 404 七种结果，核对成功收尾、其他结果保留原请求及不重复提交；普通卡片也不会自动归档。检查采用 HTTPS 传输夹具，不启动真实云服务或原生窗口。四端系统浏览器、真机、切网及后台恢复仍须按完整产品用例验收。

Android `PairingReceiptTest` 与 .NET `PairingReceiptChecks` 各覆盖十一种配对结果，补充再次查询变为未知、字符串 `"true"`、取消和存储失败；本地工作台只自动收尾重新核实成功的配对回执。运行 `tools/verify-native.py --checks android --gradle /absolute/path/to/gradlew` 或 `--checks dotnet --dotnet /absolute/path/to/dotnet` 可复验。Android 同时构建 APK，Windows C# 类型检查单独运行；均不证明目标窗口与系统生命周期。

## 协同数据库迁移

新建协同库采用格式 v2；旧 v1 普通启动返回 `storage_migration_required`，不会自动升级。先断开执行端并等待进程退出，再明确运行：

```sh
"/path/to/limelink-runtime" --migrate-storage "/path/to/device.json"
```

使用原设备配置，身份不匹配或已有运行时占用锁时拒绝执行。迁移清空 v1 缓存回执中的会话正文，保留当前有效会话正文、原命令、输入摘要、修订及 nonce；无法确认原保留期限的旧正文不会借同名新会话续期。该操作不创建额外正文备份，不连接网关或启动 Agent。格式事务遇到损坏数据会回滚，禁止通过新建空库绕过。

结果只输出格式版本和 `content_cleanup_pending`。为 `true` 时，旧读者或文件整理尚未完成；释放其他数据库读者后再次运行原迁移命令，或正常启动后的维护会继续处理。退出码成功并不独立表示所有正文副本已清除。旧版运行时不能读取 v2，不提供降级改写；正式更新、加密备份和完整回退仍待交付。

检查命令为 `cargo test --manifest-path runtime/Cargo.toml --locked --test collaboration`，覆盖 16 项协同检查，包含明确迁移、锁冲突、零网关连接、过期回执、Schema 回滚及 WAL 读者恢复，见[保留证据](evidence/content-retention.json)。

Agent 库与协同库分开，当前仍为 Agent 格式 v2，不由上述命令迁移。普通重开会按原期限清理 Agent 正文，并安排旧空闲页与 WAL 维护；读者占用时，运行时视图中的 `agent.content_cleanup_pending` 保持为 `true`，释放读者后维护继续。20 项 Agent 检查可用 `cargo test --manifest-path runtime/Cargo.toml --locked --test agent` 复现，见[Agent 保留证据](evidence/agent-content-retention.json)。这不代替安装升级、备份与回退验收。

## 从桌面安装手机 App

macOS 主网关页点击“连接手机”，或在设置中打开“手机”。Android 需官方 Platform Tools，手机开启 USB 调试、USB 安装并允许此电脑。开发测试可用 `LIMELINK_ADB` 显式指定工具路径；发行 App 当前不捆绑 ADB，不会全局安装工具。仅列出有线设备，安装前再次核对状态。

构建桌面时显式附带当前产品 APK，不能静默复用旧包：

```sh
python3 "tools/package-macos.py" \
  --gateway-bundle "/path/to/verified-gateway-bundle" \
  --android-apk "apps/android/app/build/outputs/apk/debug/app-debug.apk" \
  --aapt "/path/to/android-sdk/build-tools/36.0.0/aapt"
```

填写手机能访问的受信 HTTPS 地址后点击“安装并连接”。手机确认地址、登录或恢复原会话，再选择工作空间和电脑。`localhost` 不能代表手机上的电脑网关。系统返回 USB 安装限制时，处理手机授权后明确重试；失败不会卸载或清空数据。

iPhone 需完整 Xcode、USB 信任与开发者模式、包含当前设备签名授权的 LimeLink `.app`。当前环境尚未完成 iPhone 安装验收。Android 真机界面与连接的实际范围见[手机局部证据](evidence/android-mobile-ui.json)，安装、登录不代表配对或 Agent 任务已完成。
