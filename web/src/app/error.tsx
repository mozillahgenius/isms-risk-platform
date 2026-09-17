'use client';

import { useEffect } from 'react';

// 取得に失敗したら、それらしい空表示に化けさせず「読めなかった」と出す。
// 0 件と読めないは別のこと。ここを取り違えると、DB が落ちている間ずっと
// 「ルールが 1 件も無い」画面を見せることになる。
export default function Error({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  useEffect(() => {
    // ここはブラウザのコンソール。開発中は中身を見たいが、配備した画面では
    // 画面に出さないと決めたものをコンソールにだけ出す理由が無い（同じ相手が読む）。
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
      {/* 失敗の中身は選べない。接続に失敗すれば接続先が、認証に失敗すれば利用者名が
          文面に混ざる。画面には識別子（digest）だけ出し、中身はサーバのログで見る。
          本番ビルドの Next はそもそも message を伏せるが、それに頼らず出さない。 */}
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
