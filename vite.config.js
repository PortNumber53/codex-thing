import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    host: '0.0.0.0',
    port: 40000,
    strictPort: true,
    allowedHosts: ['dev-host.example.com'],
    proxy: {
      '/api': {
        target: 'http://127.0.0.1:40001',
        ws: true,
      },
    },
  },
})
