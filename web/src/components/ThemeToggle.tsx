'use client';

import { Moon, Sun } from '@phosphor-icons/react';

// テーマ切替。初期テーマは layout の before-paint script が html[data-theme] に確定済み。
//
// **見た目と読み上げ名は CSS だけで切り替える。**
// 以前は useSyncExternalStore で theme を読んで分岐していたが、
// サーバ側は data-theme を知りようがないので必ず light として描かれ、
// ダークで開いた利用者には hydration が終わるまで逆のアイコンが見えていた。
// 両方を DOM に置き、globals.css の [data-theme] で片方を display:none にすれば、
// 最初の描画から正しく、hydration のずれも起きない。
//
// 読み上げ名も同じ仕組みで切り替える（title 属性は補助でしかない）。

const EVT = 'isms-theme-change';

export function ThemeToggle() {
  const toggle = () => {
    // 状態は DOM を正とする。React 側に写しを持つと、写しがずれた瞬間に嘘をつく。
    const cur = document.documentElement.getAttribute('data-theme') === 'dark' ? 'dark' : 'light';
    const next = cur === 'light' ? 'dark' : 'light';
    document.documentElement.setAttribute('data-theme', next);
    try {
      localStorage.setItem('isms-theme', next);
    } catch {
      // localStorage 不可（プライベートブラウズ等）でも切替自体は続行
    }
    window.dispatchEvent(new Event(EVT));
  };

  return (
    <button type="button" onClick={toggle} className="btn btn-ghost h-9 w-9 justify-center p-0">
      <span className="theme-when-light">
        <Sun size={18} weight="bold" aria-hidden />
        <span className="sr-only">ダークモードに切り替える</span>
      </span>
      <span className="theme-when-dark">
        <Moon size={18} weight="bold" aria-hidden />
        <span className="sr-only">ライトモードに切り替える</span>
      </span>
    </button>
  );
}
