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

实际 IoT 云协议的 HTTPS/WSS/MQTT 联调仍由固定上游 `tools/test-control.mjs --native-clients` 执行；显式提供 LIMEIOT_DOTNET 可加入 .NET 属性/动作旅程，需先按上游说明构建运行时与 Console/Admin。网页专项 `--control-web` 分开使用独立临时数据库，避免合并旅程累计超过正式每账号 16 空间上限。产品工作台的云入口和完整跨网流程尚未交付，不能把上述库检查当作 App 云功能试用说明。
