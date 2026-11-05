# LimeLink 宣传站

正式域名：https://link.limeai.run。独立 Cloudflare Worker：limelink-website。

采用 Astro 静态站，复用本仓库 28 张生成图和品牌导出。首页提供渐变与可暂停的 Hero 动效；图册可筛选；品牌资源可下载；站内文档直接消费本仓库 docs。

## 本地开发

要求 Node.js 22.23.4+ 与 Python 3.10+。网站构建只使用 Python 标准库，不要求模型 Key 或参考仓库。

~~~sh
npm ci
npm run dev
npm run build
npm run test:browser
~~~

浏览器检查默认在 macOS 使用系统 Chrome；其他环境使用 Playwright Chromium，或通过 LIMELINK_BROWSER 指定浏览器路径。

## 发布

用户已授权当前任务部署到上述域名。后续部署前重新确认当前目标，执行构建、浏览器检查和 Wrangler dry-run；使用本项目固定的 wrangler.jsonc，不读取相邻网站配置。

~~~sh
npx wrangler deploy --dry-run
npx wrangler deploy
~~~

网站没有账号、预约、支付、设备控制接口或数据库。当前宣传站状态与手机/电脑产品功能状态分别记录，见[交付说明](../docs/28-website-and-deployment.md)。
