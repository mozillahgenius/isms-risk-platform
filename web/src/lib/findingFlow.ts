// 指摘の状態を進めてよい順序。画面の選択肢とサーバー側の検査の両方がここを使う（写しを置かない）。
//
// 戻してよいのは「是正済み → 是正中」（確かめたら直っていなかったとき）だけ。
// 検証済み・完了を戻せると、検証の記録（verified_by）が残ったまま、再検証なしで完了にできてしまう。

export const FINDING_STEPS = ['in_remediation', 'remediated', 'verified', 'closed'] as const;
export type FindingStep = (typeof FINDING_STEPS)[number];

/** to へ進めてよい、今の状態。 */
export const FINDING_FROM: Record<FindingStep, readonly string[]> = {
  in_remediation: ['detected', 'remediated'],
  remediated: ['in_remediation'],
  verified: ['remediated', 'retest_passed'],
  closed: ['verified'],
};

/**
 * 例外（是正せずリスクとして受け入れる）にしてよい、今の状態。
 * 検証済み・完了は是正が済んだものなので例外にしない（検証の記録が残ったまま例外になる）。
 * 例外・リスク受容はもう受け入れ済み（期限切れの例外の更新はサーバー側で別に扱う）。
 */
export const EXCEPTION_ELIGIBLE: readonly string[] = ['detected', 'in_remediation', 'remediated', 'retest_passed'];

export function canTakeException(status: string): boolean {
  return EXCEPTION_ELIGIBLE.includes(status);
}

/** 今の状態から進めてよい先。 */
export function nextFindingSteps(status: string): FindingStep[] {
  return FINDING_STEPS.filter((to) => FINDING_FROM[to].includes(status));
}
