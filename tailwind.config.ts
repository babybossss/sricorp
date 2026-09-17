import type { Config } from "tailwindcss";

/**
 * โทเคนทั้งหมดมาจาก `design/SRI OS Style Guide.dc.html`
 * ห้ามใช้สี hex ตรงๆ ในคอมโพเนนต์ ให้อ้างโทเคนที่นี่เสมอ
 */
const config: Config = {
  darkMode: ["class"],
  content: ["./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        brand: {
          50: "#EEF4FC",
          100: "#D6E4F7",
          600: "#004AAD",
          700: "#003A8A",
        },
        ink: {
          900: "#0A2540",
          600: "#425466",
          400: "#8792A2",
        },
        line: "#E3E8EE",
        canvas: "#F6F9FC",
        surface: "#FFFFFF",
        pos: { DEFAULT: "#0E9F6E", fg: "#0b7a55", bg: "#E7F7F0", bd: "#b7e6d2" },
        neg: { DEFAULT: "#DF1B41", fg: "#b51232", bg: "#FDF2F4", bd: "#f6c2ce" },
        warn: { DEFAULT: "#F5A524", fg: "#8a5200", bg: "#FDF3E4" },
        info: { DEFAULT: "#635BFF", fg: "#5b3fd6", bg: "#F3F0FE", bd: "#ded6fd" },
        // จุดสีประจำผู้ถือกรรมสิทธิ์
        holder: { corp: "#004AAD", person: "#7A5AF8", group: "#0A2540" },
      },
      fontFamily: {
        sans: ["var(--font-plex-thai)", "IBM Plex Sans Thai", "IBM Plex Sans", "system-ui", "sans-serif"],
      },
      fontSize: {
        // ผู้ใช้มีผู้สูงอายุ: เล็กสุด 16px
        sm: ["16px", "24px"],
        base: ["18px", "28px"],
        lg: ["20px", "28px"],
        h2: ["22px", "30px"],
        h1: ["28px", "36px"],
        display: ["36px", "44px"],
      },
      borderRadius: {
        DEFAULT: "10px",
        card: "12px",
        pill: "999px",
      },
      boxShadow: {
        card: "0 1px 3px rgba(10,37,64,.08)",
        pop: "0 4px 12px rgba(10,37,64,.12)",
        modal: "0 12px 40px rgba(10,37,64,.24)",
        bar: "0 8px 24px rgba(10,37,64,.28)",
        drawer: "-8px 0 30px rgba(10,37,64,.18)",
        phone: "0 8px 30px rgba(10,37,64,.14)",
      },
      minHeight: {
        // ปุ่ม desktop 52px · ปุ่มมือถือ 56px
        control: "52px",
        "control-mobile": "56px",
      },
      keyframes: {
        slidein: { from: { transform: "translateX(24px)", opacity: "0" }, to: { transform: "none", opacity: "1" } },
        fadein: { from: { opacity: "0" }, to: { opacity: "1" } },
      },
      animation: {
        slidein: "slidein .16s ease-out",
        fadein: "fadein .12s ease-out",
      },
    },
  },
  plugins: [require("tailwindcss-animate")],
};

export default config;
