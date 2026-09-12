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
  // Only known frameworks are accepted. Unknown keys fall back to the default
  // (the fallback is visible from which tab is current on screen).
  const selected = normalizeFrameworkKey(frameworkForMode(sp.framework, sp.mode));
  const result = await getRiskWorkspace(selected);
  const detail = result.ok && result.data.risks[0] ? await getRiskDetail(result.data.risks[0].id, selected) : null;
  return (
    <>
      {/* Importing initial data (design doc §8). Bulk-register assets and risks via CSV. */}
      <p className="mb-2 text-right text-[12px]">
        <Link href="/risk-management/import" className="underline underline-offset-2">CSV で資産・リスクを取り込む</Link>
      </p>
      <RiskWorkspace frameworkKey={selected} mode={mode} workspace={result.ok ? result.data : null} detail={detail?.ok ? detail.data : null} errorReason={result.ok ? undefined : result.reason} />
    </>
  );
}
