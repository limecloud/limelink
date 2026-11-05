import {test,expect} from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import {mkdir} from 'node:fs/promises';

for(const width of [390,768,1440]){
  test('首页在 '+width+'px 下可读、无溢出且图片加载',async({page})=>{
    await page.setViewportSize({width,height:900});
    await page.emulateMedia({reducedMotion:'reduce'});
    const failures=[];
    page.on('pageerror',error=>failures.push(error.message));
    await page.goto('/');
    await expect(page.getByRole('heading',{level:1})).toHaveText('小小连接，大有默契。');
    for(const section of await page.locator('main section').all()){
      await section.scrollIntoViewIfNeeded();
      await page.waitForTimeout(60);
    }
    await page.evaluate(()=>scrollTo(0,0));
    expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
    await expect.poll(()=>page.locator('main img').evaluateAll(images=>images.every(image=>image.complete&&image.naturalWidth>0))).toBe(true);
    expect(failures).toEqual([]);
    const audit=await new AxeBuilder({page}).analyze();
    expect(audit.violations).toEqual([]);
    await mkdir('../.dev/site-review',{recursive:true});
    await page.screenshot({path:'../.dev/site-review/home-'+width+'.png',fullPage:true});
  });
}

test('动效可以暂停且尊重减少动态效果',async({page})=>{
  await page.goto('/');
  const button=page.locator('.motion-button');
  await button.click();
  await expect(page.locator('.hero')).toHaveClass(/motion-paused/);
  await expect(button).toHaveAttribute('aria-pressed','true');
  await page.emulateMedia({reducedMotion:'reduce'});
  await expect(button).toBeHidden();
  expect(await page.locator('.hero-mascot').evaluate(el=>getComputedStyle(el).animationName)).toBe('none');
});

test('图册包含 28 张图，分类筛选与深链接可用',async({page})=>{
  await page.goto('/scenes/');
  await expect(page.locator('.gallery-card')).toHaveCount(28);
  await page.getByRole('button',{name:'未来硬件',exact:true}).click();
  await expect(page.locator('.gallery-card:visible')).toHaveCount(8);
  await page.getByRole('button',{name:'角色与品牌',exact:true}).click();
  await expect(page.locator('.gallery-card:visible')).toHaveCount(9);
  await page.getByRole('button',{name:'手机 · 电脑 · 网关',exact:true}).click();
  await expect(page.locator('.gallery-card:visible')).toHaveCount(11);
  await page.goto('/scenes/?filter=hardware');
  await expect(page.locator('.gallery-card:visible')).toHaveCount(8);
  await page.goto('/scenes/#28-hardware-offline');
  await expect(page.locator('[id="28-hardware-offline"]')).toBeInViewport();
});

test('手机菜单、品牌下载和文档搜索可用',async({page,request})=>{
  await page.setViewportSize({width:390,height:844});
  await page.goto('/');
  await page.getByRole('button',{name:'展开导航菜单'}).click();
  await page.locator('.mobile-menu').getByRole('link',{name:'认识柠柠'}).click();
  await expect(page).toHaveURL(/\/brand\/$/);
  const zip=await request.get('/brand/limelink-brand-kit.zip');
  expect(zip.ok()).toBe(true);
  expect((await zip.body()).subarray(0,2).toString()).toBe('PK');
  await page.goto('/docs/05-system-architecture/');
  await expect(page.locator('.prose h1')).toHaveText('系统架构');
  await expect.poll(()=>page.locator('.prose img').evaluate(image=>image.naturalWidth>0)).toBe(true);
  await page.getByRole('searchbox',{name:'筛选文档'}).fill('配对');
  await expect(page.locator('.docs-sidebar nav a:visible')).toHaveCount(1);
  expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
});

test('核心页面可访问性与错误页',async({page,request})=>{
  for(const path of ['/scenes/','/brand/','/docs/05-system-architecture/','/privacy/']){
    await page.goto(path);
    const audit=await new AxeBuilder({page}).analyze();
    expect(audit.violations,path).toEqual([]);
  }
  const missing=await request.get('/this-page-does-not-exist/');
  expect(missing.status()).toBe(404);
});
