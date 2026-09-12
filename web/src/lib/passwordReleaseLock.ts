type PasswordReleaseLock = {
  productId: 'vaultwarden-derived';
  upstreamRef: string;
  upstreamCommit: string;
  forkCommit: string | null;
  imageDigest: string | null;
};

export const DERIVED_PASSWORD_RELEASE_LOCK: PasswordReleaseLock = {
  productId: 'vaultwarden-derived',
  upstreamRef: '1.37.2',
  upstreamCommit: '46d71107f5094460dd5ecbe1dbac6e6c71e5189a',
  forkCommit: null,
  imageDigest: null,
};

// Contract for the dedicated user and status area fixed by the deployment-side provisioner.
// When changing the UID or mode, update the producer side and the reader side in the same review.
export const PASSWORD_STATUS_EVIDENCE_LOCK = {
  writerUid: 1001,
  fileMode: 0o600,
  directoryMode: 0o700,
} as const;

// forkCommit and imageDigest are pinned via code review only when an organization-managed release that has passed
// compatibility, migration, and recovery tests has been created. While null, the derived version is not made available.
