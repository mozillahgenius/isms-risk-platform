import type { Provenance } from '@/lib/catalog';

const LABEL: Record<Provenance['target'], string> = {
  dom: '標準運用モデル（DOM）',
  controls: '統制カタログ',
  risk_scenario_templates: 'リスクシナリオ雛形',
};

/**
 * 「このルールはどこから来たか」。catalog.seed_provenance の実測をそのまま出す。
 * 固定文字列を並べると、上流が動いても画面は同じ顔のままになるので、必ず DB を読む。
 */
export function ProvenanceTable({ rows, only }: { rows: Provenance[]; only?: Provenance['target'][] }) {
  const shown = only ? rows.filter((r) => only.includes(r.target)) : rows;
  if (shown.length === 0) {
    return (
      <p className="text-[13px] text-[var(--muted)]">
        出所が記録されていません（db/seeds/record_provenance.py を実行すると記録されます）。
      </p>
    );
  }
  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[720px] border-collapse text-[12px]">
        <thead>
          <tr className="border-b border-[var(--border)] text-left text-[var(--muted)]">
            <th className="py-2 pr-3 font-medium">対象</th>
            <th className="py-2 pr-3 font-medium">正本（Git）</th>
            <th className="py-2 pr-3 font-medium">commit</th>
            <th className="py-2 pr-3 font-medium">SHA-256</th>
            <th className="py-2 pr-3 font-medium">件数</th>
            <th className="py-2 pr-3 font-medium">投入</th>
          </tr>
        </thead>
        <tbody>
          {shown.map((r) => (
            <tr key={r.target} className="border-b border-[var(--border)] align-top">
              <td className="py-2 pr-3 whitespace-nowrap">{LABEL[r.target]}</td>
              <td className="py-2 pr-3">
                <div className="font-medium">{r.source_repo}</div>
                <div className="font-[family-name:var(--font-geist-mono)] text-[var(--muted)]">{r.source_path}</div>
              </td>
              <td className="py-2 pr-3 font-[family-name:var(--font-geist-mono)] whitespace-nowrap">
                {r.source_commit ? (
                  r.source_commit.slice(0, 10)
                ) : (
                  <span className="text-[var(--warning)]">未コミットの変更あり</span>
                )}
              </td>
              <td className="py-2 pr-3 font-[family-name:var(--font-geist-mono)] whitespace-nowrap">
                {r.source_sha256.slice(0, 12)}…
              </td>
              <td className="py-2 pr-3 whitespace-nowrap">{r.row_count}</td>
              <td className="py-2 pr-3 whitespace-nowrap text-[var(--muted)]">
                {new Date(r.loaded_at).toLocaleString('ja-JP', { timeZone: 'Asia/Tokyo' })}
                <div>DOM {r.dom_version}</div>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
