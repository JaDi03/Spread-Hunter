import { readFileSync } from 'node:fs'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// `vite preview` serves the same security headers as Vercel, so the CSP is tested locally
const vercel = JSON.parse(readFileSync(new URL('./vercel.json', import.meta.url), 'utf8')) as {
  headers: { headers: { key: string; value: string }[] }[]
}
const headers = Object.fromEntries(vercel.headers[0].headers.map((h) => [h.key, h.value]))

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  build: { sourcemap: false },
  preview: { headers },
})
