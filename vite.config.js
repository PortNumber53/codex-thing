import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '')
  const allowedHosts = (env.VITE_ALLOWED_HOSTS || '')
    .split(',')
    .map((host) => host.trim())
    .filter(Boolean)

  return {
    plugins: [react()],
    server: {
      host: '0.0.0.0',
      port: 40000,
      strictPort: true,
      allowedHosts,
      proxy: {
        '/api': {
          target: 'http://127.0.0.1:40001',
          ws: true,
        },
      },
    },
  }
})
