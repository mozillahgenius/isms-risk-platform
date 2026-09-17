// Kaname の画面への URL。デプロイごとに違うので env から読む（設計書 2026-09-11 §9.2）。
// 自社の URL を既定値に書くと、他社のデプロイで自社ドメインへのリンクが出るため、既定値は持たない。

type Environment = Record<string, string | undefined>;

function httpsUrl(value: string | undefined): URL | null {
  if (!value || !/^https:\/\//.test(value)) return null;
  try {
    return new URL(value);
  } catch {
    return null;
  }
}

// 端末の画面（端末の追加・登録はここで行う）。
// ISMS_KANAME_DEVICES_URL を優先し、無ければ既存の ISMS_KANAME_CONNECTORS_URL と同じ Kaname の /devices を使う。
// どちらも無ければ null（リンクを出さない）。
export function kanameDevicesUrl(environment: Environment = process.env): string | null {
  const devices = httpsUrl(environment.ISMS_KANAME_DEVICES_URL);
  if (devices) return devices.toString();
  const connectors = httpsUrl(environment.ISMS_KANAME_CONNECTORS_URL);
  return connectors ? new URL('/devices', connectors.origin).toString() : null;
}
