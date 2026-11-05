import {defineConfig} from '@playwright/test';
export default defineConfig({
  testDir:'./tests',
  workers:2,
  timeout:30000,
  use:{
    baseURL:process.env.LIMELINK_SITE_URL||'http://127.0.0.1:4351',
    browserName:'chromium',
    launchOptions:{executablePath:process.env.LIMELINK_BROWSER||(process.platform==='darwin'?'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome':undefined)},
  },
  reporter:[['list'],['json',{outputFile:'../.dev/website-browser-raw.json'}]],
  webServer:process.env.LIMELINK_SITE_URL?undefined:{command:'npm run preview -- --ignore-lock',url:'http://127.0.0.1:4351',reuseExistingServer:false},
});
