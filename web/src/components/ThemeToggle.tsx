'use client';

import { Moon, Sun } from '@phosphor-icons/react';

// Theme toggle. The initial theme is already set on html[data-theme] by the layout's before-paint script.
//
// **The appearance and the accessible name are switched by CSS alone.**
// Previously we read the theme with useSyncExternalStore and branched on it, but
// the server has no way of knowing data-theme, so it always rendered as light,
// and users who opened in dark mode saw the opposite icon until hydration finished.
// Putting both in the DOM and hiding one with display:none via [data-theme] in globals.css
// makes it correct from the first render, with no hydration mismatch.
//
// The accessible name is switched by the same mechanism (the title attribute is only supplementary).

const EVT = 'isms-theme-change';

export function ThemeToggle() {
  const toggle = () => {
    // The DOM is the source of truth for state. Keeping a copy on the React side means it lies the moment the copy drifts.
    const cur = document.documentElement.getAttribute('data-theme') === 'dark' ? 'dark' : 'light';
    const next = cur === 'light' ? 'dark' : 'light';
    document.documentElement.setAttribute('data-theme', next);
    try {
      localStorage.setItem('isms-theme', next);
    } catch {
      // Toggling still proceeds even if localStorage is unavailable (private browsing, etc.)
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
