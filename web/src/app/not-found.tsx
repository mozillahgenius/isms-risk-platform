import Link from 'next/link';

export default function NotFound() {
  return (
    <div className="card mx-auto max-w-[640px] p-6">
      <h1 className="text-[18px] font-semibold">見つかりません</h1>
      <p className="mt-2 text-[13px] text-[var(--fg-2)]">
        指定されたページまたは項目がありません。URL が壊れているか、その項目がまだ投入されていない可能性があります。
      </p>
      <div className="mt-4 flex flex-wrap gap-2">
        <Link className="btn btn-primary" href="/">
          進め方へ
        </Link>
        <Link className="btn" href="/catalog">
          カタログへ
        </Link>
        <Link className="btn" href="/graph">
          図で見る
        </Link>
      </div>
    </div>
  );
}
