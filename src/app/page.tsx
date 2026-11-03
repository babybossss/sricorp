import { redirect } from "next/navigation";

// ยังไม่ล็อกอิน middleware จะส่งไป /login เอง — ล็อกอินแล้วมาที่หน้าแรก
export default function Home() {
  redirect("/dashboard");
}
