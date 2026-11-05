# 宣传站与 Cloudflare 交付

用户新增要求：参考 Gootuan Web 的宣传内容组织和 IoT Web 的渐变、Hero 动效，在 Cloudflare 部署独立宣传站，域名为 **https://link.limeai.run**。站点源码在本仓库 site 目录，与客户端规划分别维护。

本轮定向读取页面、动效、构建与发布配置，来源为 [SRC-GOOTUAN-WEB-WEBSITE、SRC-IOTWEB-WEBSITE](evidence/sources.json)。实际文件与工作树修订见来源快照。

## 站点范围

首页说明产品价值、目标联动、网关职责、未来终端与常见问题；场景图册展示全部 28 张图并可按品牌、协同、硬件筛选；品牌页提供同一母版导出的资源包；文档中心直接消费本仓库 Markdown，保留站内相对链接和原始资源下载。

本轮宣传站不新增账号、报名、支付、数据库、产品 API 或设备控制。没有 App 制品时不放置伪造的下载按钮，硬件场景明确标为概念。对 Gootuan Web 的学习不产生 Gootuan 的后台、预约数据或运行绑定依赖。

## 技术与动效

采用 Astro 静态构建，少量浏览器原生脚本处理图册筛选、文档搜索、移动导航和 Hero 暂停。没有为了宣传站引入完整 React 运行时。依赖版本和锁文件由 site/package.json、package-lock.json 固定。

Hero 使用 CSS 渐变、角色轻浮动和连接线流动，复用本轮生成资产，不虚构生成视频。提供暂停按钮；尊重减少动态效果；页面隐藏和 Hero 离开视口时暂停。图片使用 WebP、实际尺寸和延迟加载，首屏角色优先加载。

## 显式资源边界

site/scripts/prepare-assets.py 从本仓库 docs 和 output/imagegen 复制资料、预览、原图及品牌包到 public。生成的 public 目录和 dist 忽略提交，构建不读取相邻产品目录，也不携带图像 API Key。资源导出器的 Pillow/OpenCV 依赖属于设计工具，普通网站构建只需 Python 标准库。

站点所读 Markdown、图像、来源 JSON 都是本轮计划公开的资料；参考仓库绝对路径与个人凭据不得进入制品。未来私有资料必须显式排除，不能因为存在本地文件就自动对外发布。

## 构建与验证

~~~sh
cd "site"
npm ci
npm run build
npm run test:browser
~~~

构建检查站内链接、锚点、28 张图像覆盖和秘密样式。浏览器检查桌面/平板/手机布局、导航、筛选、图像、减少动态效果、资源下载、文档和可访问性。检查范围和结果进入独立的网站验证记录，不把网站可访问升级为手机/电脑协同已实现。

## 发布目标

Cloudflare Worker 名为 limelink-website，采用静态 Assets。wrangler.jsonc 固定 link.limeai.run 自定义域名；不包含平台 API、D1、Cron 或相邻网站绑定。此次部署已由用户明确授权。

发布前完成构建与浏览器检查，检查 dry-run 目标，发布后核验 HTTPS 首页、图册、品牌下载、文档、静态图片、robots、sitemap 和 404。实际 Worker 版本、域名结果和制品摘要见[部署记录](evidence/website-deployment.json)，浏览器结果见[网站检查](evidence/website-browser.json)。

后续回退应引用本产品已核验的旧版本，不对其他 Worker 或域名执行操作。网站部署与产品发布分别留证。用户后续已授权实现完成后的版本提交和推送；不能因网站上线而提前放行原生产品。
