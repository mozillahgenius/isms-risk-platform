'use client';

// 送る前に確認を出すボタン（2026-09-25）。取り消せない操作（端末の登録を外す等）に使う。
export default function ConfirmSubmitButton({ message, children }: { message: string; children: React.ReactNode }) {
  return (
    <button
      type="submit"
      className="btn px-2 py-1 text-[11px]"
      onClick={(event) => {
        if (!window.confirm(message)) event.preventDefault();
      }}
    >
      {children}
    </button>
  );
}
