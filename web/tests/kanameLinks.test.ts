import { describe, expect, it } from 'vitest';
import { kanameDevicesUrl } from '../src/lib/kanameLinks';

describe('Kaname の端末の画面への URL', () => {
  it('ISMS_KANAME_DEVICES_URL を優先する', () => {
    expect(kanameDevicesUrl({
      ISMS_KANAME_DEVICES_URL: 'https://kaname.example.com/devices',
      ISMS_KANAME_CONNECTORS_URL: 'https://other.example.com/connectors',
    })).toBe('https://kaname.example.com/devices');
  });

  it('無ければ ISMS_KANAME_CONNECTORS_URL と同じ Kaname の /devices を使う', () => {
    expect(kanameDevicesUrl({
      ISMS_KANAME_CONNECTORS_URL: 'https://kaname.example.com/settings/connectors?x=1',
    })).toBe('https://kaname.example.com/devices');
  });

  it('https 以外や壊れた値は使わない', () => {
    expect(kanameDevicesUrl({ ISMS_KANAME_DEVICES_URL: 'http://kaname.example.com/devices' })).toBeNull();
    expect(kanameDevicesUrl({ ISMS_KANAME_DEVICES_URL: 'javascript:alert(1)' })).toBeNull();
    expect(kanameDevicesUrl({ ISMS_KANAME_DEVICES_URL: 'https://' })).toBeNull();
  });

  it('どちらも無ければ null（自社の URL を既定値にしない）', () => {
    expect(kanameDevicesUrl({})).toBeNull();
  });
});
