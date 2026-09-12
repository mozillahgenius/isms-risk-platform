import Link from 'next/link';
import { RiskMapTimeline } from '@/components/RiskMapTimeline';
import { LatestRiskLevel } from '@/components/LatestRiskLevel';
import {
  ISMS_FRAMEWORK_KEY,
  ISMS_SHARED_LEDGER_DESCRIPTION,
  RESOURCE_MANAGEMENT_NAME,
  type AppMode,
} from '@/lib/navigation';
import type { RiskDetail, RiskWorkspaceData } from '@/lib/riskRegister';

type Props = {
  frameworkKey: string;
  mode?: AppMode;
  workspace: RiskWorkspaceData | null;
  detail: RiskDetail | null;
  errorReason?: string;
};

const reasonText: Record<string, string> = {
  no_token: 'テナントセッションが未設定です。SSO連携後に運用データを表示します。',
  invalid_session: 'テナントセッションが失効しています。再認証後に表示できます。',
  error: 'テナントデータを取得できませんでした。サーバーログを確認してください。',
};

function tags(items: string[]) {
  return items.map((tag) => <span key={tag} className="badge badge-note">{tag}</span>);
}

export function RiskWorkspace({ frameworkKey, mode, workspace, detail, errorReason }: Props) {
  const isIsmsLens = frameworkKey === ISMS_FRAMEWORK_KEY;
  const frameworkSearch = `framework=${encodeURIComponent(frameworkKey)}${mode ? `&mode=${mode}` : ''}`;
  return (
    <div className="flex flex-col gap-5">
      <div>
        <div>
          <p className="text-[12px] font-medium text-[var(--accent)]">{isIsmsLens ? 'ISMS / ISO 27001:2022' : RESOURCE_MANAGEMENT_NAME}</p>
          <h1 className="mt-1 text-[22px] font-semibold tracking-tight">{isIsmsLens ? 'ISMS' : RESOURCE_MANAGEMENT_NAME}</h1>
          <p className="mt-1 max-w-[820px] text-[13px] text-[var(--muted)]">
            {isIsmsLens
              ? `${ISMS_SHARED_LEDGER_DESCRIPTION} CIA、管理策、証跡、監査状態を確認します。`
              : `資産、リスク、施策を共通台帳に登録します。${ISMS_SHARED_LEDGER_DESCRIPTION} Phase は独立項目として集計します。`}
          </p>
        </div>
      </div>

      <section className="flex min-w-0 flex-col gap-4">
          {errorReason ? (
            <div className="card border-[var(--warning)] bg-[var(--warning-weak)] p-4 text-[13px] text-[var(--fg-2)]">{reasonText[errorReason] ?? reasonText.error}</div>
          ) : null}
          {!workspace ? (
            <div className="card p-6 text-[13px] text-[var(--muted)]">運用データはまだ表示できません。</div>
          ) : (
            <>
              <div className="grid gap-3 sm:grid-cols-3">
                {[
                  ['資産', workspace.assets.length, '分類・所有対象'],
                  ['リスク', workspace.risks.length, 'Phase別の評価対象'],
                  ['施策', workspace.measures.length, '評価を変える対応'],
                ].map(([label, count, note]) => (
                  <div key={String(label)} className="card p-4">
                    <div className="text-[12px] text-[var(--muted)]">{label}</div>
                    <div className="mt-1 text-[25px] font-semibold tabular-nums">{count}</div>
                    <div className="mt-1 text-[11px] text-[var(--muted)]">{note}</div>
                  </div>
                ))}
              </div>

              <section className="card overflow-hidden">
                <div className="flex flex-wrap items-center justify-between gap-2 border-b border-[var(--border)] px-4 py-3">
                  <div>
                    <h2 className="text-[15px] font-semibold">Phase別リスク台帳</h2>
                    <p className="mt-1 text-[12px] text-[var(--muted)]">Phase、領域、資産、最新のリスクレベルを横断して確認します。</p>
                  </div>
                  <Link className="btn btn-primary" href={`/risk-management/risks?${frameworkSearch}`}>リスクを登録</Link>
                </div>
                <div className="overflow-x-auto">
                  <table className="min-w-[900px] w-full border-collapse text-[13px]">
                    <thead>
                      <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                        <th className="px-4 py-2 font-medium">Phase</th>
                        <th className="px-4 py-2 font-medium">リスク</th>
                        <th className="px-4 py-2 font-medium">資産</th>
                        <th className="px-4 py-2 font-medium">最新レベル</th>
                        <th className="px-4 py-2 font-medium">履歴</th>
                      </tr>
                    </thead>
                    <tbody>
                      {workspace.risks.map((risk) => (
                        <tr key={risk.id} className="border-b border-[var(--border)] align-top last:border-0 hover:bg-[var(--surface-2)]">
                          <td className="px-4 py-3"><span className="badge">Phase {risk.phase}</span><div className="mt-1 text-[11px] text-[var(--muted)]">{risk.area}</div></td>
                          <td className="px-4 py-3"><Link className="font-medium underline underline-offset-2" href={`/risk-management/risks/${risk.id}?${frameworkSearch}`}>{risk.risk_key} {risk.summary}</Link><div className="mt-1 flex flex-wrap gap-1">{tags(risk.tags)}</div></td>
                          <td className="px-4 py-3 text-[12px] text-[var(--muted)]">{risk.assets.length ? risk.assets.map((asset) => asset.name).join('、') : '未紐付け'}</td>
                          <td className="px-4 py-3"><LatestRiskLevel level={risk.latest_level} stage={risk.latest_stage} /></td>
                          <td className="px-4 py-3 text-[12px] text-[var(--muted)]">{risk.snapshot_count}件</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </section>

              <div className="grid gap-4 xl:grid-cols-2">
                <section className="card p-4">
                  <div className="flex items-center justify-between gap-2"><h2 className="text-[15px] font-semibold">資産マスタ</h2><Link className="text-[12px] underline" href={`/risk-management/assets?${frameworkSearch}`}>一覧と編集</Link></div>
                  <div className="mt-3 flex flex-col gap-2">{workspace.assets.slice(0, 5).map((asset) => <div key={asset.id} className="border-t border-[var(--border)] pt-2 first:border-0 first:pt-0"><div className="flex flex-wrap items-center justify-between gap-2"><span className="font-medium">{asset.asset_key} {asset.name}</span><span className="badge">{asset.classification_name}</span></div><div className="mt-1 flex flex-wrap gap-1">{tags(asset.tags)}</div></div>)}</div>
                </section>
                <section className="card p-4">
                  <div className="flex items-center justify-between gap-2"><h2 className="text-[15px] font-semibold">施策マスタ</h2><Link className="text-[12px] underline" href={`/risk-management/measures?${frameworkSearch}`}>一覧と編集</Link></div>
                  <div className="mt-3 flex flex-col gap-2">{workspace.measures.slice(0, 5).map((measure) => <div key={measure.id} className="border-t border-[var(--border)] pt-2 first:border-0 first:pt-0"><div className="flex flex-wrap items-center justify-between gap-2"><span className="font-medium">{measure.measure_key} {measure.name}</span><span className="badge">{measure.strategy}</span></div><p className="mt-1 text-[12px] text-[var(--muted)]">{measure.summary}</p></div>)}</div>
                </section>
              </div>

              {detail ? <section className="card p-4"><div className="mb-4"><p className="text-[11px] font-[family-name:var(--font-geist-mono)] text-[var(--muted)]">{detail.risk.risk_key}</p><h2 className="mt-1 text-[16px] font-semibold">選択中のリスク: {detail.risk.summary}</h2></div><RiskMapTimeline snapshots={detail.snapshots} /></section> : null}
            </>
          )}
      </section>
    </div>
  );
}
