import Link from 'next/link';
import { getIncidentWorkspace } from '@/lib/incidentRegister';
import { saveIncident } from '@/app/incidents/actions';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'インシデント管理' };

const SEVERITY_LABEL: Record<string, string> = {
  critical: '重大', high: '高', medium: '中', low: '低',
};
const STATUS_LABEL: Record<string, string> = {
  open: '対応中', contained: '封じ込め済み', closed: '解決済み',
};

function formatDate(value: string | Date | null): string {
  if (!value) return '—';
  return new Date(value).toLocaleString('ja-JP', { dateStyle: 'short', timeStyle: 'short' });
}

// datetime-local inputのdefaultValueは "YYYY-MM-DDTHH:mm[:ss]" 形式が要る
// (タイムゾーン表記があると値が入らない)。編集フォームにこの入力欄が無いと、
// 更新のたびにoccurred_at/detected_atがNULLへ上書きされてしまう
// (Codexレビュー2026-09-02指摘)。秒まで含めるのは、分単位に丸めると既存の
// 秒を持つ値(このUI以外の経路で入った値)がタイトル等の編集だけで欠けるため
// (同レビュー2回目の指摘)。inputには step="1" を付けて秒を保持できるようにする。
function toDatetimeLocal(value: string | Date | null): string {
  if (!value) return '';
  const d = new Date(value);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

export default async function IncidentsPage({ searchParams }: { searchParams: Promise<{ mode?: string }> }) {
  const [result, sp] = await Promise.all([getIncidentWorkspace(), searchParams]);
  const data = result.ok ? result.data : null;
  const mode = sp.mode === 'isms' || sp.mode === 'risk' ? sp.mode : null;
  return (
    <div className="flex flex-col gap-5">
      <div>
        <div className="flex flex-wrap items-center justify-between gap-2"><h1 className="text-[21px] font-semibold">インシデント管理</h1><Link className="btn px-3 py-1.5 text-[12px]" href={`/operations/assignments?work_type=incident_response${mode ? `&mode=${mode}` : ''}`}>作業を依頼</Link></div>
        <p className="mt-1 text-[13px] text-[var(--muted)]">インシデント対応・報告の作業を作成し、担当メンバーが報告を登録できます。</p>
      </div>
      {!data ? <div className="card p-5 text-[13px] text-[var(--muted)]">テナントセッションが必要です。</div> : <>
        <form action={saveIncident} className="card grid gap-3 p-4 md:grid-cols-2">
          {mode ? <input type="hidden" name="mode" value={mode} /> : null}
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">件名<input className="input" name="title" placeholder="不審メールによる情報漏えいの疑い" required /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">状況・対応の要約<textarea className="input min-h-20" name="summary" placeholder="何が起きたか、現在の対応状況" /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">重大度<select className="input" name="severity" defaultValue=""><option value="">未設定</option><option value="critical">重大</option><option value="high">高</option><option value="medium">中</option><option value="low">低</option></select></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">状態<select className="input" name="status" defaultValue="open"><option value="open">対応中</option><option value="contained">封じ込め済み</option><option value="closed">解決済み</option></select></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">発生日時<input className="input" name="occurred_at" type="datetime-local" /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">検知日時<input className="input" name="detected_at" type="datetime-local" /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">関連リスク<select className="input" name="related_risk_id" defaultValue=""><option value="">なし</option>{data.risks.map((r) => <option key={r.id} value={r.id}>{r.theme}</option>)}</select></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">関連施策<select className="input" name="related_measure_id" defaultValue=""><option value="">なし</option>{data.measures.map((m) => <option key={m.id} value={m.id}>{m.measure_key} {m.name}</option>)}</select></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">アサイン先(リスクオーナー)<select className="input" name="assignee_user_id" defaultValue=""><option value="">未アサイン</option>{data.riskOwners.filter((o) => o.is_active_pool).map((o) => <option key={o.user_id} value={o.user_id}>{o.display_name}{o.department_name ? `(${o.department_name})` : ''}</option>)}</select></label>
          <div className="md:col-span-2"><button className="btn btn-primary" type="submit">インシデントを登録</button></div>
        </form>
        <section className="card overflow-x-auto"><table className="min-w-[1100px] w-full border-collapse text-[13px]"><thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]"><th className="px-4 py-2 font-medium">件名</th><th className="px-4 py-2 font-medium">重大度</th><th className="px-4 py-2 font-medium">状態</th><th className="px-4 py-2 font-medium">発生日時</th><th className="px-4 py-2 font-medium">関連リスク</th><th className="px-4 py-2 font-medium">アサイン先</th><th className="px-4 py-2 font-medium">編集</th></tr></thead><tbody>{data.incidents.map((incident) => {
          const unassigned = !incident.assignee_user_id;
          return (
            <tr key={incident.id} className="border-b border-[var(--border)] align-top last:border-0">
              <td className="px-4 py-3"><div className="font-medium">{incident.title}</div><div className="mt-1 max-w-[320px] text-[12px] text-[var(--muted)]">{incident.summary}</div></td>
              <td className="px-4 py-3">{incident.severity ? <span className="badge">{SEVERITY_LABEL[incident.severity]}</span> : '—'}</td>
              <td className="px-4 py-3"><span className="badge">{STATUS_LABEL[incident.status]}</span></td>
              <td className="px-4 py-3 text-[12px] tabular-nums">{formatDate(incident.occurred_at)}</td>
              <td className="px-4 py-3 text-[12px] text-[var(--muted)]">{incident.related_risk_theme ?? '—'}</td>
              <td className="px-4 py-3 text-[12px]">
                {unassigned
                  ? <span className="badge badge-client">未アサイン{incident.suggested_owner_name ? `(提案: ${incident.suggested_owner_name})` : ''}</span>
                  : incident.assignee_name}
              </td>
              <td className="px-4 py-3"><details><summary className="cursor-pointer text-[12px] underline">編集</summary><form action={saveIncident} className="mt-3 grid min-w-[320px] gap-2 rounded-[var(--radius)] bg-[var(--surface-2)] p-3">{mode ? <input type="hidden" name="mode" value={mode} /> : null}<input type="hidden" name="id" value={incident.id} /><input className="input" name="title" defaultValue={incident.title} required /><textarea className="input" name="summary" defaultValue={incident.summary} /><select className="input" name="severity" defaultValue={incident.severity ?? ''}><option value="">未設定</option><option value="critical">重大</option><option value="high">高</option><option value="medium">中</option><option value="low">低</option></select><select className="input" name="status" defaultValue={incident.status}><option value="open">対応中</option><option value="contained">封じ込め済み</option><option value="closed">解決済み</option></select><label className="flex flex-col gap-1 text-[11px] text-[var(--muted)]">発生日時<input className="input" name="occurred_at" type="datetime-local" step="1" defaultValue={toDatetimeLocal(incident.occurred_at)} /></label><label className="flex flex-col gap-1 text-[11px] text-[var(--muted)]">検知日時<input className="input" name="detected_at" type="datetime-local" step="1" defaultValue={toDatetimeLocal(incident.detected_at)} /></label><select className="input" name="related_risk_id" defaultValue={incident.related_risk_id ?? ''}><option value="">なし</option>{data.risks.map((r) => <option key={r.id} value={r.id}>{r.theme}</option>)}</select><select className="input" name="related_measure_id" defaultValue={incident.related_measure_id ?? ''}><option value="">なし</option>{data.measures.map((m) => <option key={m.id} value={m.id}>{m.measure_key} {m.name}</option>)}</select><label className="flex flex-col gap-1 text-[11px] text-[var(--muted)]">アサイン先{unassigned && incident.suggested_owner_name ? <span className="text-[var(--muted)]">(提案: {incident.suggested_owner_name}。選択すると確定)</span> : null}<select className="input" name="assignee_user_id" defaultValue={incident.assignee_user_id ?? ''}><option value="">未アサイン</option>{data.riskOwners.filter((o) => o.is_active_pool || o.user_id === incident.assignee_user_id).map((o) => <option key={o.user_id} value={o.user_id}>{o.display_name}{o.is_active_pool ? '' : '(現在は対象外)'}</option>)}</select></label><button className="btn btn-primary" type="submit">更新</button></form></details></td>
            </tr>
          );
        })}</tbody></table></section>
      </>}
    </div>
  );
}
