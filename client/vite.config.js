import { defineConfig } from 'vite'

// The built, reviewed bundle is committed below priv/client and is served by
// Quod itself.  No client dependency is loaded from a floating CDN at runtime.
export default defineConfig({
  base: './',
  build: { outDir: '../priv/client', emptyOutDir: true },
})
