import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { dirname, resolve } from 'node:path';
import { copyFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const swaggerDist = dirname(require.resolve('swagger-ui-dist/swagger-ui-bundle.js'));

export default defineConfig({
  plugins: [react(), {
    name: 'copy-swagger-ui',
    closeBundle() {
      const target = resolve(__dirname, '../internal/httpapi/webdist');
      copyFileSync(resolve(swaggerDist, 'swagger-ui-bundle.js'), resolve(target, 'swagger-ui-bundle.js'));
      copyFileSync(resolve(swaggerDist, 'swagger-ui.css'), resolve(target, 'swagger-ui.css'));
    },
  }],
  build: { outDir: resolve(__dirname, '../internal/httpapi/webdist'), emptyOutDir: true },
  server: { proxy: { '/api': 'http://127.0.0.1:8080' } },
});
