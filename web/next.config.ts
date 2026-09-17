import type { NextConfig } from 'next';

// 社内・ローカル限定の閲覧アプリ。SSO はまだ無いので、外に出さない前提の頭を付ける。
// （bind は package.json の -H 127.0.0.1 で担保。ここはブラウザ側の締め付け。）
const securityHeaders = [
  { key: 'X-Frame-Options', value: 'DENY' },
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  {
    key: 'Permissions-Policy',
    value: 'camera=(), microphone=(), geolocation=(), browsing-topics=(), interest-cohort=()',
  },
  { key: 'X-DNS-Prefetch-Control', value: 'off' },
  // 外部への通信を持たない画面なので、既定で自分自身だけに閉じる。
  // WebGL/Canvas は外部リソースを使わない。dev は HMR の eval が要るため緩める。
  {
    key: 'Content-Security-Policy',
    value: [
      "default-src 'self'",
      process.env.NODE_ENV === 'production'
        ? "script-src 'self' 'unsafe-inline'"
        : "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: blob:",
      "font-src 'self' data:",
      process.env.NODE_ENV === 'production' ? "connect-src 'self'" : "connect-src 'self' ws:",
      "frame-ancestors 'none'",
      "base-uri 'self'",
      "form-action 'self'",
    ].join('; '),
  },
];

const nextConfig: NextConfig = {
  async headers() {
    return [{ source: '/:path*', headers: securityHeaders }];
  },
  experimental: {
    serverActions: {
      // oauth2-proxy(reverse_proxy構成、pass_host_header=false)が upstream への
      // x-forwarded-host に本来のドメインでなくTailscale IP:portを送るため、
      // Server ActionsのCSRF検証(Origin一致確認)がこのドメインからの正規リクエストを
      // 拒否してしまう(2026-09-01 実機調査で確認)。公開ドメインを明示的に許可する。
      allowedOrigins: ['management.example.invalid'],
    },
  },
};

export default nextConfig;
