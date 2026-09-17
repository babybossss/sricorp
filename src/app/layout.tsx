import type { Metadata } from "next";
import { IBM_Plex_Sans_Thai } from "next/font/google";
import "@/styles/globals.css";

const plexThai = IBM_Plex_Sans_Thai({
  subsets: ["thai", "latin"],
  weight: ["400", "500", "600", "700"],
  variable: "--font-plex-thai",
  display: "swap",
});

export const metadata: Metadata = {
  title: "SRI OS · Company OS",
  description: "ระบบ ERP / Company OS ของ Family Office — SRI Corporation",
  // ใช้โลโก้ไฟล์เดียวกับที่หน้าอื่นใช้ ไม่ต้องมีสำเนา icon.png อีกชุด
  icons: { icon: "/sri-logo.png" },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="th" className={plexThai.variable}>
      <body>{children}</body>
    </html>
  );
}
