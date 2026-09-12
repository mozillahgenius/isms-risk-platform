import { Suspense, type ReactNode } from 'react';
import { AppHeader, AppMobileNavigation, AppSidebarNavigation } from '@/components/AppShell';
import { RESOURCE_MANAGEMENT_NAME } from '@/lib/navigation';

function HeaderFallback() {
  return (
    <header className="h-[68px] border-b border-[var(--border)] bg-[var(--surface)]">
      <div className="mx-auto flex h-full max-w-[1400px] items-center px-5 text-[15px] font-semibold">
        {RESOURCE_MANAGEMENT_NAME}
      </div>
    </header>
  );
}

export function AppShellFrame({ children }: { children: ReactNode }) {
  return (
    <>
      <Suspense fallback={<HeaderFallback />}>
        <AppHeader />
      </Suspense>
      <Suspense fallback={null}>
        <AppMobileNavigation />
      </Suspense>
      <div className="mx-auto flex w-full max-w-[1400px] flex-1 lg:items-stretch">
        <aside className="sticky top-[68px] hidden h-[calc(100dvh-68px)] w-[264px] shrink-0 overflow-y-auto border-r border-[var(--border)] py-6 pr-4 lg:block">
          <Suspense fallback={<p className="px-3 text-xs text-[var(--muted)]">メニューを読み込み中</p>}>
            <AppSidebarNavigation />
          </Suspense>
        </aside>
        <main className="min-w-0 flex-1 px-5 py-6 lg:px-8">{children}</main>
      </div>
      <footer className="border-t border-[var(--border)] px-5 py-4 text-[12px] text-[var(--muted)] lg:pl-[calc((100vw-min(100vw,1400px))/2+296px)]">
        ルールの正本は Git、運用台帳はテナント境界付きで管理します。
      </footer>
    </>
  );
}
