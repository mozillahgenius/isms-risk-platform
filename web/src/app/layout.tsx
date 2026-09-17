import type { Metadata } from 'next';
import { AppShellFrame } from '@/components/AppShellFrame';
import { RESOURCE_MANAGEMENT_NAME } from '@/lib/navigation';
import './globals.css';

// ページ側で title を上書きする（各画面で現在地を正しく示す）。
export const metadata: Metadata = {
  title: { default: 'ダッシュボード', template: `%s｜${RESOURCE_MANAGEMENT_NAME}` },
  description: 'ISMSを含むリスク管理、運用証跡、デバイス統制を一つの台帳で管理する',
};

// FOUC / hydration mismatch を避けるため、描画前に data-theme を確定させる。
// 優先順位: localStorage の明示値（light/dark）> prefers-color-scheme。
const themeInit = `(function(){try{var t=localStorage.getItem('isms-theme');if(t!=='light'&&t!=='dark'){t=window.matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light';}document.documentElement.setAttribute('data-theme',t);}catch(e){}})();`;

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="ja" suppressHydrationWarning className="h-full antialiased">
      <head>
        <script suppressHydrationWarning dangerouslySetInnerHTML={{ __html: themeInit }} />
      </head>
      <body className="flex min-h-full flex-col">
        <AppShellFrame>{children}</AppShellFrame>
      </body>
    </html>
  );
}
