# 构建与隔离试用

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

`tools/verify-native.py --checks runtime apple macos android dotnet` 按指定项执行并记录真实退出码/源码摘要。缺失工具需通过 `--gradle`、`--dotnet` 和进程级 `JAVA_HOME/ANDROID_HOME` 指定；不修改系统全局配置，也不自动接受本机 SDK 许可。跳过项不记为通过。

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

桌面“本机终端”选择配置并启动。手机工作台填写受信 HTTPS 网关，登录自己的所有者会话，明确选择空间与电脑并请求配对；在电脑核对名称/指纹后批准。该流程要求两端属于同一 IoT 所有者，不是跨账号分享。

发送后先查询原请求并完成已核实记录，再发起下一项动作。卡片受理与实际展示分别看待；会话编辑前取得 30 秒输入资格。冲突后重新读取，不擅自覆盖对方内容。

## 隔离联合检查

准备 Rust 编译的 `limeiot-gateway`、`limeiot-model-validator`、`limeiot-simulator` 及 Mosquitto。通过进程环境显式设置 `LIMEIOT_TEST_TARGET_DIR` 与 `LIMEIOT_MOSQUITTO`，不在脚本中隐式寻找相邻仓库。

```sh
cargo test --manifest-path "runtime/Cargo.toml" --locked
cargo build --manifest-path ".dev/iot-source/Cargo.toml" --locked --bin limeiot-gateway --bin limeiot-model-validator --bin limeiot-simulator
node "tools/test-iot-link.mjs" --iot-root ".dev/iot-source" --mtls
```

测试自动创建本仓库 `.dev/` 下的独立临时空间、数据库、凭据和短期 CA，使用本机回环端口，不接触现有家庭或生产网关。mTLS 检查通过不代表 HTTPS 用户界面或真机验证通过。

macOS 可另运行 `tools/test-macos-ui.mjs --iot-root .dev/iot-source`，通过真正窗口批准并编辑测试会话；手机仍是软件夹具。测试提示在 `.dev/macos-ui-progress.json`；操作完成后写入 `.dev/macos-ui-finish` 内容 `done` 关闭隔离栈。脚本不会替你通过本机私有 stdin 批准。

## 产品云核心检查

固定 SDK 后运行 `node tools/test-cloud-clients.mjs`，需要 Swift、JDK 21 和 .NET 10；通过 `--dotnet <可执行文件路径>` 指定 .NET。可以用 `--platform apple`、`--platform android` 或 `--platform dotnet` 单独验证，Android 仍使用进程级 JAVA_HOME/ANDROID_HOME。

脚本先核对导出的 SDK 与 lock，再启动独立的回环 HTTP 夹具。它验证真实产品库的本地空间签名、原请求恢复、404 不重发及跨空间阻塞；输出 `.dev/cloud-clients-*.json`，含输入摘要和明确的 fixture/native_app/hardware 边界。常规 Android Core 检查未启动夹具时会跳过这条专项，用脚本运行才实际验收它。CI 三个宿主 job 均执行对应专项；iOS 另做模拟器编译。

实际 IoT 云协议的 HTTPS/WSS/MQTT 联调仍由固定上游 `tools/test-control.mjs --native-clients` 执行；显式提供 LIMEIOT_DOTNET 可加入 .NET 属性/动作旅程，需先按上游说明构建运行时与 Console/Admin。网页专项 `--control-web` 分开使用独立临时数据库，避免合并旅程累计超过正式每账号 16 空间上限。上述库联调与工作台界面验收分别记录，不能由库检查推定完整跨网界面旅程通过。

## 云工作台试用与恢复

在工作台选择云控制面，输入精确 HTTPS origin。可以恢复既有会话，或明确点击“发起 / 恢复授权”：界面显示授权码，系统浏览器只打开 SDK 核对过的同 origin 授权地址。在浏览器核对平台、授权码和账号后批准，回到应用按间隔明确查询结果。离开前台会停止当前等待；如授权提示已清空，点击恢复云会话，或恢复原授权后查询，不会自动另建授权。

登录后明确选择云空间并刷新唯一有效网关与电脑。核对网关、本地空间、绑定修订、电脑及指纹后再申请本机配对；桌面执行端仍须由电脑用户明确批准。云操作只支持现有受限动作，模型草稿继续使用本地网关入口。

响应丢失时在“当前账号全部空间的原操作”选择原记录，查询原请求或明确核对原网关回执。无需重新选择原设备，也不能重发；结果未知会阻止新的提交。完成终态记录或放弃尚未提交的准备记录必须明确点击，未知记录由 SDK 拒绝清除。

`swift run -j 4 WorkbenchChecks` 验证 Apple 实际工作台模型的 7 组授权、路由、恢复和生命周期行为；`python3 tools/verify-native.py --checks apple-workbench` 记录源文件摘要。检查采用 HTTPS 传输夹具，不启动真实云服务或原生窗口。四端系统浏览器、真机、切网及后台恢复仍须按完整产品用例验收。
