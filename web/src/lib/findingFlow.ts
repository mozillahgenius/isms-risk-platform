// Order in which a finding's state may advance. Both the screen's options and the server-side check use this (no copies).
//
// The only allowed step back is "remediated -> remediating" (when checking reveals it was not actually fixed).
// If verified or completed could be stepped back, it could be completed without re-verification while the verification record (verified_by) remains.

export const FINDING_STEPS = ['in_remediation', 'remediated', 'verified', 'closed'] as const;
export type FindingStep = (typeof FINDING_STEPS)[number];

/** Current states from which it may advance to `to`. */
export const FINDING_FROM: Record<FindingStep, readonly string[]> = {
  in_remediation: ['detected', 'remediated'],
  remediated: ['in_remediation'],
  verified: ['remediated', 'retest_passed'],
  closed: ['verified'],
};

/**
 * Current states from which it may be made an exception (accepted as a risk without remediation).
 * Verified and completed are already remediated, so they are not made exceptions (it would become an exception with the verification record still in place).
 * Exception and risk acceptance are already accepted (renewal of an expired exception is handled separately on the server side).
 */
export const EXCEPTION_ELIGIBLE: readonly string[] = ['detected', 'in_remediation', 'remediated', 'retest_passed'];

export function canTakeException(status: string): boolean {
  return EXCEPTION_ELIGIBLE.includes(status);
}

/** States it may advance to from the current state. */
export function nextFindingSteps(status: string): FindingStep[] {
  return FINDING_STEPS.filter((to) => FINDING_FROM[to].includes(status));
}
