import type { AssetRow, RegisterFramework } from '@/lib/riskRegister';
import { RESOURCE_MANAGEMENT_NAME } from '@/lib/navigation';

export function FrameworkFields({ frameworks, selected }: { frameworks: RegisterFramework[]; selected: string }) {
  return (
    <fieldset className="flex flex-col gap-2">
      <legend className="text-[12px] font-medium text-[var(--muted)]">枠組みタグ</legend>
      <div className="flex flex-wrap gap-3">
        {frameworks.map((framework) => (
          <label key={framework.key} className="inline-flex items-center gap-1.5 text-[12px]">
            <input type="checkbox" name="framework_keys" value={framework.key} defaultChecked={framework.key === selected || framework.key === 'RISK-MANAGEMENT'} />
            {framework.key === 'RISK-MANAGEMENT' ? RESOURCE_MANAGEMENT_NAME : framework.name_ja}
          </label>
        ))}
      </div>
    </fieldset>
  );
}

export function AssetFields({ assets }: { assets: AssetRow[] }) {
  return (
    <fieldset className="flex flex-col gap-2">
      <legend className="text-[12px] font-medium text-[var(--muted)]">関連資産</legend>
      <div className="grid gap-2 sm:grid-cols-2">
        {assets.map((asset) => (
          <label key={asset.id} className="inline-flex items-start gap-1.5 text-[12px]">
            <input type="checkbox" name="asset_ids" value={asset.id} />
            <span><span className="font-[family-name:var(--font-geist-mono)]">{asset.asset_key}</span> {asset.name}</span>
          </label>
        ))}
      </div>
      {assets.length === 0 ? <p className="text-[11px] text-[var(--muted)]">先にこの枠組みの資産を登録してください。</p> : null}
    </fieldset>
  );
}
