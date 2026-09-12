// Of the e-learning sync, only the decisions that don't touch the DB live here (so they can be tested in isolation).

/** How to handle a completion revocation. `none` = no matching course / `deferred` = hold without applying. */
export type InvalidationTarget = { kind: 'none' } | { kind: 'deferred' };

/**
 * Decides whether to apply a completion revocation (incomplete) to a record.
 *
 * **Currently there is no case where it is applied. If a matching course exists, this always returns deferred.**
 *
 * In 0054, courses became rows keyed by (source_system, external_training_id, fiscal_year).
 * But incomplete rows have no completed_at (the parser forces null),
 * so the response cannot tell "which fiscal year the revocation is for".
 *
 * "If the DB has only one fiscal year, the revocation is for that year" doesn't hold either. If the DB has
 * only FY2026 rows and an FY2025 revocation is re-synced, it would wrongly reset
 * an evaluated FY2026 record to unevaluated. The DB state doesn't indicate the response's fiscal year, so it isn't a valid basis.
 *
 * Losing evaluated evidence by mistake is the unrecoverable outcome, so we hold without applying and show the count in the UI.
 * That's why the fiscal year itself isn't accepted (it couldn't be used for the decision, and using it would bring back the error above).
 * Once the source payload carries the fiscal year, add it as an argument and return the matching row.
 *
 * Note that the separate path that resets an evaluation to unevaluated when a row re-imported as completed
 * has changed content still works. That path has completed_at, so the fiscal year is determined.
 */
export function invalidationTarget(courseExists: boolean): InvalidationTarget {
  return courseExists ? { kind: 'deferred' } : { kind: 'none' };
}
