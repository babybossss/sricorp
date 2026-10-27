import { defineConfig } from "vitest/config";
import path from "node:path";

export default defineConfig({
  // .tsx = เทสต์คอมโพเนนต์ (render เป็น HTML บน node ด้วย react-dom/server) · tsconfig ใช้ jsx: preserve จึงสั่ง transformer เอง (vite ตัวนี้ใช้ oxc)
  oxc: { jsx: { runtime: "automatic" } },
  test: { environment: "node", include: ["src/**/*.test.{ts,tsx}"] },
  resolve: { alias: { "@": path.resolve(__dirname, "src") } },
});
