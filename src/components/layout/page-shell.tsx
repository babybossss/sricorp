import { Sidebar } from "./sidebar";
import { Topbar } from "./topbar";
import { Toast } from "./toast";

/** โครงหน้าเดียวกันทุกหน้า: sidebar 256px + top bar 72px + main 24px */
export function PageShell({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="flex min-h-screen items-start">
      <Sidebar />
      <div className="flex min-w-0 flex-1 flex-col">
        <Topbar title={title} />
        <main className="w-full max-w-[1368px] p-6">{children}</main>
      </div>
      <Toast />
    </div>
  );
}
