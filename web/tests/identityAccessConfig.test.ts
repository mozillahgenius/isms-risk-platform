import { describe, expect, it } from 'vitest';
import { hasIdentityProvisioningConfiguration } from '../src/lib/identityAccessConfig';

describe('ID・ライセンス実行面の非秘密設定', () => {
  const valid = {
    IDENTITY_PROVISIONING_PROVIDER: 'google_workspace',
    IDENTITY_PROVISIONING_DISPATCH_URL: 'https://worker.example.com/v1/provisioning/requests',
    IDENTITY_PROVISIONING_ALLOWED_ORIGIN: 'https://worker.example.com',
    IDENTITY_PROVISIONING_DISPATCH_TOKEN: 'a'.repeat(32),
  };

  it('固定pathと許可originが一致するHTTPS設定だけを受理する', () => {
    expect(hasIdentityProvisioningConfiguration(valid)).toBe(true);
    expect(hasIdentityProvisioningConfiguration({ ...valid, IDENTITY_PROVISIONING_DISPATCH_URL: 'https://' })).toBe(false);
    expect(hasIdentityProvisioningConfiguration({ ...valid, IDENTITY_PROVISIONING_DISPATCH_URL: 'https://token@worker.example.com/v1/provisioning/requests' })).toBe(false);
    expect(hasIdentityProvisioningConfiguration({ ...valid, IDENTITY_PROVISIONING_DISPATCH_URL: 'https://worker.example.com/v1/provisioning/requests?target=x' })).toBe(false);
    expect(hasIdentityProvisioningConfiguration({ ...valid, IDENTITY_PROVISIONING_ALLOWED_ORIGIN: 'https://other.example.com' })).toBe(false);
  });

  it('空白tokenと未許可providerを拒否する', () => {
    expect(hasIdentityProvisioningConfiguration({ ...valid, IDENTITY_PROVISIONING_DISPATCH_TOKEN: ' '.repeat(32) })).toBe(false);
    expect(hasIdentityProvisioningConfiguration({ ...valid, IDENTITY_PROVISIONING_PROVIDER: 'custom' })).toBe(false);
  });
});
