'use client';

import { useEffect } from 'react';

// On fetch failure, say "could not read" instead of disguising it as a plausible empty display.
// 0 items and unreadable are different things. Confusing them would, for as long as the DB is down,
// show a screen saying "there are no rules".
export default function Error({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  useEffect(() => {
    // This is the browser console. We want to see the contents during development, but on a deployed screen
    // there is no reason to log to the console only what we decided not to show on screen (the same audience reads it).
    if (process.env.NODE_ENV === 'development') {
      console.error(error);
    } else {
      console.error('画面の描画に失敗しました。digest:', error.digest ?? '(なし)');
    }
  }, [error]);

  return (
    <div className="card mx-auto max-w-[760px] p-6">
      <h1 className="text-[18px] font-semibold text-[var(--danger)]">表示できませんでした</h1>
      <p className="mt-2 text-sm text-[var(--fg-2)]">
        DB から読めなかった可能性があります。<b>0 件ではありません。</b>
      </p>
      {/* We cannot choose what the failure contains. A connection failure puts the connection target into the text,
          an auth failure the user name. Show only the identifier (digest) on screen and see the contents in server logs.
          Production Next builds hide message anyway, but we do not rely on that and do not show it. */}
      {error.digest && (
        <p className="mt-4 font-[family-name:var(--font-geist-mono)] text-[12px] text-[var(--muted)]">
          digest: {error.digest}
        </p>
      )}
      <ul className="mt-4 list-disc pl-5 text-[13px] text-[var(--muted)]">
        <li>PostgreSQL が動いているか（pg_isready）</li>
        <li>接続先が合っているか（環境変数 ISMS_WEB_DATABASE_URL）</li>
        <li>マイグレーションと seed が済んでいるか（make db-reset / make seed）</li>
        <li>詳しい理由はサーバのログに出ている</li>
      </ul>
      <button type="button" onClick={reset} className="btn btn-primary mt-5">
        再試行
      </button>
    </div>
  );
}
