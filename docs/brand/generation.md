# 图像生成、继承与复现

本轮按用户指定的 API 路径调用 **https://img.aishenji.top/v1**，请求模型为 **gpt-image-2.5-flare** 和 **gpt-image-2.5-sunburst**。执行使用 imagegen 技能随附的 CLI，没有修改该工具或自行实现 SDK 调用器。

模型名称记录的是请求字段。第三方服务内部的实际模型、转发策略和计费实现不可由本地图片证明；不把模型别名写成已核验的上游产品版本。API Key 仅在调用进程环境使用，不保存到仓库。

## 母版继承

~~~text
01 flare 探索 ── 留作对比
02 sunburst 探索 ── 03 平面标志 ── 固定双色 SVG / 各端图标
                 └─ 04 角色多视图 ── 06～20 品牌和协同场景
                                  └─ 05 硬件外观 ── 21～28 硬件生活场景
~~~

05 先实际生成并审阅，再用于硬件生活场景。06～20 的角色图主要参考 04；场景图仍可能发生细节漂移，不能覆盖母版。新版本使用新文件名和新的记录，不静默覆盖已经评审的资产。

## 提示词与记录

每张图的完整提示词位于 [prompts](prompts/)。[scene-plan.json](scene-plan.json)保存 05～28 的计划及阶段，[image-generation.json](image-generation.json)保存全部 01～28 的实际文件摘要、请求模型、请求尺寸、实际尺寸、引用和结果。原始 PNG 保留在 [output/imagegen](../../output/imagegen/)。

本轮服务部分返回尺寸与请求尺寸不同；以实际图片解码结果为准，不能把 requested_size 当作实际像素。部分探索图含 alpha，预览统一合成白底；透明底标志由确定性提取生成，单独检查 alpha，不把白底或棋盘格声称为透明。

CLI 本轮没有保存服务 request_id、服务端模型证明或可核验的费用明细；这些字段保持未知。局部 API 返回格式错误和后续重试如实记录，不以失败的请求计入生成图数量。

## 本地复现方法

调用需要用户可用的同一服务与模型权限。先在本地安全设置 OPENAI_API_KEY；不要把值写进命令历史、提示词或文档。OPENAI_BASE_URL 指向用户指定服务。以下 IMAGE_GEN 变量指向本机安装的 imagegen 技能 CLI：

~~~sh
export OPENAI_BASE_URL="https://img.aishenji.top/v1"
python "$IMAGE_GEN" edit \
  --model "gpt-image-2.5-flare" \
  --image "output/imagegen/05-hardware-master.png" \
  --prompt-file "docs/brand/prompts/21-hardware-desk.txt" \
  --size "1536x1024" --quality high --no-augment \
  --out "output/imagegen/21-hardware-desk-v2.png"
~~~

只设置服务 URL 和模型名称不能保证重现相同图片；模型生成具有随机性，服务也可能更新。SHA-256 用于确认本轮文件身份，不承诺重新生成字节一致。

## 检查与使用边界

视觉检查关注轮廓、叶片、脸的位置、场景动作、网关角色、明显手部/设备畸形、文字和裁切。技术检查关注解码、尺寸、alpha、重复摘要、引用及导出一致性。结果和局部限制见 [visual-verification.json](visual-verification.json)。

场景图中的路径只是示意，正式系统职责以[架构图](../05-system-architecture.md)为准。效果图中的文字不作为 UI 文案或合同。视觉审阅不能证明软件功能、机械可制造性、硬件性能、无近似商标或服务商的商业授权条件。
