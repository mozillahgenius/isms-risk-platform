import 'server-only';

import { withTenant, type TenantReadResult } from './tenant';

/** 取り込みの記録（0071）の一覧。新しい順。取り消したものは取り消しの結果も一緒に出す。 */
export type ImportBatchRow = {
  id: string;
  kind: string;
  sha256: string;
  row_count: number;
  created_count: number;
  importer_name: string | null;
  imported_at: string;
  undone_at: string | null;
  undoer_name: string | null;
  retired_count: number | null;
  skipped_count: number | null;
};

export async function getImportHistory(): Promise<TenantReadResult<ImportBatchRow[]>> {
  return withTenant(async (sql) => sql<ImportBatchRow[]>`
    SELECT b.id, b.kind, encode(b.file_sha256, 'hex') AS sha256, b.row_count, b.created_count,
           u.display_name AS importer_name,
           to_char(b.imported_at AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD HH24:MI') AS imported_at,
           to_char(x.undone_at AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD HH24:MI') AS undone_at,
           xu.display_name AS undoer_name, x.retired_count, x.skipped_count
      FROM app.import_batches b
      LEFT JOIN app.users u ON u.tenant_id = b.tenant_id AND u.id = b.imported_by
      LEFT JOIN app.import_undos x ON x.tenant_id = b.tenant_id AND x.batch_id = b.id
      LEFT JOIN app.users xu ON xu.tenant_id = x.tenant_id AND xu.id = x.undone_by
     ORDER BY b.imported_at DESC
     LIMIT 50`);
}
