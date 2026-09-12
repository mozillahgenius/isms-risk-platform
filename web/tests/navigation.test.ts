import { describe, expect, it } from 'vitest';
import {
  frameworkForMode,
  ISMS_SHARED_LEDGER_DESCRIPTION,
  isRouteActive,
  modeDestination,
  navigationForMode,
  RESOURCE_MANAGEMENT_NAME,
  resolveAppMode,
} from '../src/lib/navigation';

describe('アプリモードのURL判定', () => {
  it('ISMSの導線をISMS専用モードに解決する', () => {
    expect(resolveAppMode('/')).toBe('isms');
    expect(resolveAppMode('/steps/risk-assessment')).toBe('isms');
    expect(resolveAppMode('/wizard')).toBe('isms');
    expect(resolveAppMode('/iso27001')).toBe('isms');
  });

  it('横断運用画面はリスク管理全体モードに解決する', () => {
    expect(resolveAppMode('/dashboard')).toBe('risk');
    expect(resolveAppMode('/operations/device-control')).toBe('risk');
    expect(resolveAppMode('/risk-management')).toBe('risk');
  });

  it('共通画面はmodeクエリを優先し、既存frameworkクエリも解釈する', () => {
    expect(resolveAppMode('/operations/passwords', 'mode=isms')).toBe('isms');
    expect(resolveAppMode('/operations/passwords', 'mode=risk')).toBe('risk');
    expect(resolveAppMode('/risk-management', 'framework=ISO27001%3A2022')).toBe('isms');
  });

  it('ISMSモードでは矛盾する枠組み指定をISO 27001へ正規化する', () => {
    expect(frameworkForMode('RISK-MANAGEMENT', 'isms')).toBe('ISO27001:2022');
    expect(frameworkForMode('IPO-KARTE', 'risk')).toBe('IPO-KARTE');
    expect(frameworkForMode('ISO27001:2022', 'risk')).toBe('RISK-MANAGEMENT');
    expect(modeDestination('/catalog/controls', 'framework=ISO27001%3A2022', 'risk'))
      .toBe('/catalog/controls?framework=RISK-MANAGEMENT&mode=risk');
  });

  it('共通画面の切替は現在地を保ち、固有画面は各モードの入口へ移る', () => {
    expect(modeDestination('/operations/passwords', '', 'isms')).toBe('/operations/passwords?mode=isms');
    expect(modeDestination('/risk-management', '', 'isms')).toBe('/');
  });

  it('既存のリスク管理URLは互換導線として維持する', () => {
    expect(resolveAppMode('/risk-management')).toBe('risk');
    expect(modeDestination('/risk-management', '', 'risk')).toBe('/dashboard');
  });
});

describe('リソースマネジメントの表示', () => {
  it('正式名称と共通台帳上のISMSレンズを案内する', () => {
    const riskItems = navigationForMode('risk').flatMap((section) => section.items);

    expect(riskItems).toContainEqual(expect.objectContaining({
      href: '/risk-management?framework=RISK-MANAGEMENT',
      label: RESOURCE_MANAGEMENT_NAME,
    }));
    expect(riskItems.some((item) => item.href.startsWith('/resource-management'))).toBe(false);
    expect(RESOURCE_MANAGEMENT_NAME).toBe('リソースマネジメント');
    expect(ISMS_SHARED_LEDGER_DESCRIPTION).toContain('同一の資産・リスクID');
    expect(ISMS_SHARED_LEDGER_DESCRIPTION).toContain('ISO 27001:2022');
  });
});

describe('ISMSナビゲーションの階層', () => {
  it('ISMSを親にして、ステップを子メニューとして保持する', () => {
    const ismsSections = navigationForMode('isms');
    const isms = ismsSections[0];
    const steps = isms.children?.find((section) => section.label === 'ステップ');
    const organization = ismsSections.find((section) => section.label === '組織管理');

    expect(isms.label).toBe('ISMS');
    expect(isms.collapsible).toBe(true);
    expect(isms.items.some((item) => item.label === '組織・メンバー')).toBe(false);
    expect(steps?.collapsible).toBe(true);
    expect(steps?.children?.length).toBeGreaterThan(0);
    expect(steps?.children?.flatMap((section) => section.items).some((item) => item.href === '/steps/risk-assessment')).toBe(true);
    expect(organization?.items).toContainEqual(expect.objectContaining({ label: '組織・メンバー' }));
  });
});

describe('ナビゲーションの現在地', () => {
  it('セグメント境界で現在地を判定する', () => {
    expect(isRouteActive('/operations/device-control', { href: '/operations', label: '運用' })).toBe(false);
    expect(isRouteActive('/operations/device-control', { href: '/operations/device-control', label: 'デバイス' })).toBe(true);
    expect(isRouteActive('/catalogue', { href: '/catalog', label: 'カタログ' })).toBe(false);
    expect(isRouteActive('/risk-management', { href: '/risk-management?framework=IPO-KARTE', label: '上場準備' }, 'framework=IPO-KARTE')).toBe(true);
    expect(isRouteActive('/risk-management', { href: '/risk-management?framework=RISK-MANAGEMENT', label: '全リスク' }, 'framework=IPO-KARTE')).toBe(false);
  });
});
