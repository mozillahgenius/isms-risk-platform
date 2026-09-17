import 'server-only';

import type { TransactionSql } from 'postgres';

/**
 * メール送信キューへ積むところ。
 *
 * Web プロセスは SMTP 資格情報を持たない。ここは app.mail_outbox に行を足すだけで、
 * 実際の送信は scripts/send_mail_outbox.py が別プロセス・別資格情報で行う。
 * ISMS の対象システム自身が社外への送信口を直接握らない形にしておく
 * （誤送信を 1 クリックで起こせない・送信の記録がキューに必ず残る）。
 */

export type MailPurpose = 'external_questionnaire' | 'work_assignment' | 'agent_distribution';

export type QueuedMail = {
  purpose: MailPurpose;
  toEmail: string;
  toName?: string;
  subject: string;
  bodyText: string;
  relatedType?: string;
  relatedId?: string;
};

/**
 * 利用者が開く画面の URL。**予備値を持たない**（設計書 2026-09-11 §9.2）。
 * 予備値に自社の URL を書くと、他社のデプロイで ISMS_WEB_BASE_URL を入れ忘れたときに
 * 自社ドメインへのリンクが社外宛てのメールに載る。未設定ならリンクを出さない。
 */
export function baseUrl(): string | null {
  const configured = process.env.ISMS_WEB_BASE_URL;
  if (configured && /^https?:\/\//.test(configured)) return configured.replace(/\/+$/, '');
  return null;
}

export async function queueMail(sql: TransactionSql, mail: QueuedMail): Promise<string> {
  const rows = await sql<{ id: string }[]>`
    INSERT INTO app.mail_outbox
      (tenant_id, purpose, to_email, to_name, subject, body_text,
       related_type, related_id, created_by, updated_by)
    VALUES
      (app.current_tenant(), ${mail.purpose}, ${mail.toEmail.toLowerCase()}::citext,
       ${mail.toName ?? ''}, ${mail.subject}, ${mail.bodyText},
       ${mail.relatedType ?? null}, ${mail.relatedId ?? null}::uuid,
       app.current_session_user(), app.current_session_user())
    RETURNING id`;
  const id = rows[0]?.id;
  if (!id) throw new Error('mail not queued');
  return id;
}

/** 依頼された本人へ送る通知。宛先は社内なので、詳細は本文に書いてよい。 */
export function assignmentNotificationBody(input: {
  assigneeName: string;
  requesterName: string;
  workTypeLabel: string;
  title: string;
  instructions: string;
  resourceLabel: string | null;
  assignmentRoleLabel: string;
  dueDate: string | null;
}): string {
  const lines = [
    `${input.assigneeName} さん`,
    '',
    `${input.requesterName} さんから作業の依頼が届きました。`,
    '',
    `■ 作業種別: ${input.workTypeLabel}`,
    `■ 作業:     ${input.title}`,
    `■ 担当区分: ${input.assignmentRoleLabel}`,
    `■ 期限:     ${input.dueDate ?? '指定なし'}`,
  ];
  if (input.resourceLabel) lines.push(`■ 対象:     ${input.resourceLabel}`);
  lines.push('', '■ 依頼内容', input.instructions.trim() || '（記載なし）', '');
  const url = baseUrl();
  lines.push(url
    ? `受領・進捗の更新はこちらから: ${url}/operations/assignments?scope=mine`
    : '受領・進捗の更新は、管理画面の「自分の担当」から行ってください。');
  return lines.join('\n');
}

/** 社外（委託先・クラウド事業者）へ送る質問票。宛先が社外なので書きすぎない。 */
export function questionnaireMailBody(input: {
  organizationName: string;
  recipientName: string;
  vendorName: string;
  title: string;
  purpose: string;
  dueDate: string | null;
  questions: { ordinal: number; prompt: string; answer_type: string; options: unknown; required: boolean }[];
  contactEmail: string;
}): string {
  const lines = [
    `${input.vendorName}${input.recipientName ? ` ${input.recipientName} 様` : ' ご担当者様'}`,
    '',
    `${input.organizationName} です。いつもお世話になっております。`,
    `${input.title} へのご回答をお願いいたします。`,
  ];
  if (input.purpose.trim()) lines.push('', `【目的】${input.purpose.trim()}`);
  if (input.dueDate) lines.push('', `【ご回答期限】${input.dueDate}`);
  lines.push('', '恐れ入りますが、本メールに返信する形で、各設問の下にご回答をご記入ください。', '');
  lines.push('----------------------------------------------------------------');
  for (const question of input.questions) {
    const options = Array.isArray(question.options) ? question.options : [];
    let hint = '';
    if (question.answer_type === 'boolean') hint = '（はい / いいえ）';
    else if (question.answer_type === 'single_choice' && options.length > 0) {
      hint = `（${options.map(String).join(' / ')} のいずれか）`;
    }
    lines.push(`問${question.ordinal}. ${question.prompt}${question.required ? '' : '（任意）'}`);
    if (hint) lines.push(`     ${hint}`);
    lines.push('     回答:');
    lines.push('');
  }
  lines.push('----------------------------------------------------------------', '');
  lines.push('ご不明な点は本メールへご返信ください。');
  lines.push(`（送信元窓口: ${input.contactEmail}）`);
  return lines.join('\n');
}
