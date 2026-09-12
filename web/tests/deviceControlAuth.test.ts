import { describe, expect, it } from 'vitest';
import {
  buildDeviceDispatchPayload,
  isEmailAuthorizedForDeviceControl,
  isProxySecretValid,
  parseDeviceControlDevices,
  trustedProxyEmail,
} from '../src/lib/deviceControlAuth';

describe('操作対象端末の許可リスト(ISMS_DEVICE_CONTROL_DEVICES)', () => {
  it('未設定・空なら0台(fail-closed)', () => {
    expect(parseDeviceControlDevices(undefined)).toEqual([]);
    expect(parseDeviceControlDevices('')).toEqual([]);
    expect(parseDeviceControlDevices('  ')).toEqual([]);
    expect(parseDeviceControlDevices('[]')).toEqual([]);
  });

  it('JSON配列の key / label を前後空白を除いて読む', () => {
    expect(parseDeviceControlDevices(
      '[{"key":" device-a ","label":"Example laptop A"},{"key":"device-b","label":" Example laptop B "}]',
    )).toEqual([
      { key: 'device-a', label: 'Example laptop A' },
      { key: 'device-b', label: 'Example laptop B' },
    ]);
  });

  it('形が崩れていれば全体を捨てる(部分的に読まない)', () => {
    expect(parseDeviceControlDevices('not json')).toEqual([]);
    expect(parseDeviceControlDevices('{"key":"device-a","label":"A"}')).toEqual([]);
    expect(parseDeviceControlDevices('[{"key":"device-a","label":"A"},{"key":"","label":"B"}]')).toEqual([]);
    expect(parseDeviceControlDevices('[{"key":"device-a","label":"A"},{"key":"device-b"}]')).toEqual([]);
    expect(parseDeviceControlDevices('[{"key":"device-a","label":"A"},null]')).toEqual([]);
  });

  it('同じ key の重複は拒否する', () => {
    expect(parseDeviceControlDevices('[{"key":"device-a","label":"A"},{"key":"device-a","label":"A2"}]')).toEqual([]);
  });
});

describe('端末操作の監査ペイロード', () => {
  it('実行者、理由、テンプレート版を必須属性として正規化する', () => {
    expect(buildDeviceDispatchPayload({
      device_key: ' device-1 ',
      template_id: 'patch.macos_update',
      template_version: '2026-09-04.1',
      request_id: 'request-1',
      actor_email: ' Admin@Example.com ',
      reason: ' 月次更新 ',
    })).toEqual({
      device_key: 'device-1',
      template_id: 'patch.macos_update',
      template_version: '2026-09-04.1',
      request_id: 'request-1',
      actor_email: 'admin@example.com',
      reason: '月次更新',
    });
  });

  it('理由または帰属情報が欠けた要求を拒否する', () => {
    const base = {
      device_key: 'device-1', template_id: 'patch.macos_update', template_version: '2026-09-04.1',
      request_id: 'request-1', actor_email: 'admin@example.com', reason: '月次更新',
    };
    expect(buildDeviceDispatchPayload({ ...base, reason: ' ' })).toBeNull();
    expect(buildDeviceDispatchPayload({ ...base, actor_email: '' })).toBeNull();
    expect(buildDeviceDispatchPayload({ ...base, template_version: '' })).toBeNull();
  });
});

describe('端末操作の認可(fail-closed)', () => {
  it('許可リスト未設定なら誰も許可しない', () => {
    expect(isEmailAuthorizedForDeviceControl('alice@example.com', undefined)).toBe(false);
    expect(isEmailAuthorizedForDeviceControl('alice@example.com', '')).toBe(false);
  });

  it('メールが無ければ許可しない(ヘッダ未転送の経路をfail-closedにする)', () => {
    expect(isEmailAuthorizedForDeviceControl(null, 'alice@example.com')).toBe(false);
    expect(isEmailAuthorizedForDeviceControl('', 'alice@example.com')).toBe(false);
  });

  it('許可リストに一致すれば許可する(大文字小文字・前後空白を無視)', () => {
    expect(isEmailAuthorizedForDeviceControl('Alice@Example.com', ' alice@example.com , bob@example.com')).toBe(true);
  });

  it('許可リストに無いメールは拒否する', () => {
    expect(isEmailAuthorizedForDeviceControl('mallory@example.com', 'alice@example.com')).toBe(false);
  });
});

describe('nginx/oauth2-proxy共有シークレット(x-forwarded-emailヘッダ偽装への耐性)', () => {
  const SECRET = 'a'.repeat(32);

  it('期待値が未設定(短すぎる/空)なら誰も許可しない', () => {
    expect(isProxySecretValid(SECRET, undefined)).toBe(false);
    expect(isProxySecretValid(SECRET, '')).toBe(false);
    expect(isProxySecretValid(SECRET, 'short')).toBe(false);
  });

  it('受信したヘッダが無ければ拒否する(直接到達経路でヘッダごと省略された場合)', () => {
    expect(isProxySecretValid(null, SECRET)).toBe(false);
    expect(isProxySecretValid(undefined, SECRET)).toBe(false);
    expect(isProxySecretValid('', SECRET)).toBe(false);
  });

  it('一致すれば許可する', () => {
    expect(isProxySecretValid(SECRET, SECRET)).toBe(true);
  });

  it('不一致(偽装値)は拒否する', () => {
    expect(isProxySecretValid('b'.repeat(32), SECRET)).toBe(false);
    expect(isProxySecretValid(SECRET.slice(0, -1) + 'x', SECRET)).toBe(false);
    // Also reject spoofed values of a different length (guessing attacks)
    expect(isProxySecretValid(SECRET + 'extra', SECRET)).toBe(false);
  });
});

describe('一般Web書き込みのプロキシ本人性', () => {
  const SECRET = 'c'.repeat(32);

  it('秘密ヘッダと正規化可能なメールが揃った場合だけ本人を返す', () => {
    expect(trustedProxyEmail(SECRET, SECRET, ' User@Example.com ')).toBe('user@example.com');
    expect(trustedProxyEmail('wrong', SECRET, 'user@example.com')).toBeNull();
    expect(trustedProxyEmail(SECRET, SECRET, 'not-an-email')).toBeNull();
    expect(trustedProxyEmail(SECRET, SECRET, null)).toBeNull();
  });
});
