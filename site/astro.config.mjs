import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://link.limeai.run',
  output: 'static',
  trailingSlash: 'always',
  build: { inlineStylesheets: 'never' },
});
