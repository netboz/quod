import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// The production bundle is committed into priv/explorer/, where the node's cowboy
// listener (quod_explorer) serves it — the Erlang release needs no node tooling.
// `npm run dev` proxies /api and /ws to a locally running node.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  base: './',
  build: { outDir: '../priv/explorer', emptyOutDir: true },
  server: {
    proxy: {
      '/api': 'http://127.0.0.1:14569',
      '/ws': { target: 'ws://127.0.0.1:14569', ws: true },
    },
  },
})
