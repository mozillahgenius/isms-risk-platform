import Link from 'next/link';
import { RiskWorkspace } from '@/components/RiskWorkspace';
import { frameworkForMode } from '@/lib/navigation';
import { getRiskDetail, getRiskWorkspace, normalizeFrameworkKey } from '@/lib/riskRegister';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'リソースマネジメント' };

type SearchParams = Promise<Record<string, string | string[] | undefined>>;

export default async function RiskManagementPage({ searchParams }: { searchParams: SearchParams }) {
  const sp = await searchParams;
  const requestedMode = Array.isArray(sp.mode) ? sp.mode[0] : sp.mode;
  const mode = requestedMode === 'isms' || requestedMode === 'risk' ? requestedMode : undefined;
  // 既知の枠組みだけを受ける。知らないキーは既定へ落とす
  // （落ちたことは画面のタブの現在地で分かる）。
  const selected = normalizeFrameworkKey(frameworkForMode(sp.framework, sp.mode));
  const result = await getRiskWorkspace(selected);
  const detail = result.ok && result.data.risks[0] ? await getRiskDetail(result.data.risks[0].id, selected) : null;
  return (
    <>
      {/* 初期データの取り込み（設計書 §8）。資産・リスクを CSV で一括登録する。 */}
      <p className="mb-2 text-right text-[12px]">
        <Link href="/risk-management/import" className="underline underline-offset-2">CSV で資産・リスクを取り込む</Link>
      </p>
      <RiskWorkspace frameworkKey={selected} mode={mode} workspace={result.ok ? result.data : null} detail={detail?.ok ? detail.data : null} errorReason={result.ok ? undefined : result.reason} />
    </>
  );
}
