import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { resolve } from 'path';

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      '@openstr/shared': resolve(__dirname, '../shared/index.ts'),
    },
  },
  server: {
    port: 5173,
    proxy: {
      // Only better-auth goes through this proxy (axios calls the API directly
      // via VITE_API_URL). The API mounts better-auth at /api/auth, and prod
      // nginx preserves the prefix too, so do not strip it here.
      '/api': {
        target: 'http://localhost:3000',
        changeOrigin: true,
      },
      '/photos': {
        target: 'http://localhost:3000',
        changeOrigin: true,
      },
    },
  },
});
