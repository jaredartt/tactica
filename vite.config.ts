import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// GitHub Pages serves this repo from /tactica/, so the production build needs
// that prefix on its asset URLs. The dev server stays at the root.
export default defineConfig(({ mode }) => ({
  plugins: [react()],
  base: mode === 'production' ? '/tactica/' : '/',
  server: { port: 5173 },
}))
