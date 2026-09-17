// eラーニングの同期のうち、DB を触らない判断だけをここに置く（単体で検査するため）。

/** 完了取消をどう扱うか。`none` = 対象の講座が無い / `deferred` = 当てずに保留する。 */
export type InvalidationTarget = { kind: 'none' } | { kind: 'deferred' };

/**
 * 完了取消（incomplete）を記録へ当てるかどうかを決める。
 *
 * **いまは、当てる場合が無い。対象の講座があれば必ず deferred を返す。**
 *
 * 0054 で講座は (source_system, external_training_id, fiscal_year) 単位の行になった。
 * ところが incomplete 行は completed_at を持たない（parser が null を強制する）ため、
 * 応答からは「どの年度の取消なのか」を判定できない。
 *
 * 「DB に1年度分しか無ければ、その年度の取消だ」も成り立たない。DB に 2026 年度の
 * 行しか無い状態で 2025 年度分の取消が再同期されれば、2026 年度の評価済み記録を
 * 誤って未評価へ戻す。DB の状態は応答の年度を示さないので、根拠にならない。
 *
 * 評価済みの証跡が誤って消えるほうが回復不能なので、当てずに保留し、件数を画面へ出す。
 * だから年度そのものは受け取らない（受け取っても判定に使えず、使えば上の誤りに戻る）。
 * 取込元のペイロードが年度を持つようになったら、その値を引数に足して一致する行を返す。
 *
 * なお、完了として再取込された行の内容が変わったときに評価を未評価へ戻す経路は
 * これとは別で、いまも動く。そちらは completed_at があるので年度が確定する。
 */
export function invalidationTarget(courseExists: boolean): InvalidationTarget {
  return courseExists ? { kind: 'deferred' } : { kind: 'none' };
}
