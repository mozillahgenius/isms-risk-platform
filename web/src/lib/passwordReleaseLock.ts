type PasswordReleaseLock = {
  productId: 'intelligent-beast-vaultwarden-derived';
  upstreamRef: string;
  upstreamCommit: string;
  forkCommit: string | null;
  imageDigest: string | null;
};

export const IB_PASSWORD_RELEASE_LOCK: PasswordReleaseLock = {
  productId: 'intelligent-beast-vaultwarden-derived',
  upstreamRef: '1.37.2',
  upstreamCommit: '46d71107f5094460dd5ecbe1dbac6e6c71e5189a',
  forkCommit: null,
  imageDigest: null,
};

// RUNTIMEのprovisionerが固定する専用llmユーザーとstatus領域の契約。
// UIDやモードを変更する場合は、生成側と読取側を同じreviewで更新する。
export const PASSWORD_STATUS_EVIDENCE_LOCK = {
  writerUid: 1001,
  fileMode: 0o600,
  directoryMode: 0o700,
} as const;

// forkCommitとimageDigestは、互換・移行・復旧試験を通した会社管理releaseを
// 作成した時だけcode reviewで固定する。nullの間は派生版を利用可能にしない。
