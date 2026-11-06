# 跨端资源交付

首批平面资源来自同一 [Logo 母版](../../output/imagegen/03-mark-master.png)，经固定双色、透明底和尺寸导出生成。这些平面资源已用于四端工程；桌面最新版改用独立的 [3D 图标导出](desktop-design.md)，正式商店与安装器显示仍需目标系统验收。

| 平台 | 本轮文件 | 使用边界 |
| --- | --- | --- |
| macOS | [LimeLink.icns](assets/macos/LimeLink.icns)、[iconset](assets/macos/LimeLink.iconset/) | 包含 16～1024 像素资源；菜单栏使用单色模板 |
| Windows | [LimeLink.ico](assets/windows/LimeLink.ico)、[PNG](assets/windows/) | ICO 含 16～256 像素；512 PNG 独立保留；MSIX 各比例和目标尺寸后续按实际 manifest 接入 |
| iOS | [AppIcon-1024.png](assets/ios/AppIcon-1024.png)、[Contents.json](assets/ios/Contents.json) | 不透明、无预切圆角的现代通用图标；放入真实 AppIcon.appiconset 后进行 Xcode/设备检查 |
| Android | [分层资源](assets/android/)、[adaptive XML](assets/android/ic_launcher.xml) | 前景/单色层 432px，图形高度 55%；背景独立；按实际资源目录接入，API 26+ 使用 adaptive、旧版使用 legacy |
| Web/PWA | [图标](assets/web/)、[favicon.ico](assets/web/favicon.ico) | 16～512px，含 180px 入口；manifest、maskable 策略由真实 Web 产品补充 |
| 通用模板 | [menu-16.png](assets/templates/menu-16.png)、[32px](assets/templates/menu-32.png)、[64px](assets/templates/menu-64.png) | 单色透明，用于菜单栏/通知入口；Android 通知须按系统要求转换为白色 alpha 模板并实机检查 |

Android XML 引用同目录资源的基名；接入时把 PNG 放入对应 drawable 目录，把 XML 放入 mipmap-anydpi-v26，旧版图标映射到各密度。Android 13 单色层、不同启动器的圆形/方形/水滴裁切必须独立检查，不以 432px 尺寸正确代替实机通过。

## 可复现导出

导出器不连接图片服务，依赖 Pillow、NumPy 和 OpenCV。建议安装到隔离的开发环境，不要求文档读者安装这些包：

~~~sh
uv venv ".dev/venv"
uv pip install --python ".dev/venv/bin/python" pillow numpy opencv-python-headless
".dev/venv/bin/python" "docs/scripts/export_brand.py"
~~~

export_brand.py 根据母版颜色提取轮廓、用固定色值填充并生成标准尺寸，记录所有文件的 SHA-256、尺寸及 alpha 范围。矢量是对本轮生成轮廓的追踪，未进行专业字标设计和曲线节点精修。

图标一致性与文件完整性见 [exports.json](exports.json)。后续图标资源接入需在目标平台检查系统缩放、暗色背景、启动器蒙版、焦点/可访问名称和安装器显示；当前已接入四端工程，macOS 窗口有局部验证；四端系统缩放与安装器仍需分别验收。
