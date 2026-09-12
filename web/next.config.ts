import type { NextConfig } from 'next';

// Internal / local-only viewing app. There is no SSO yet, so set headers assuming it is not exposed externally.
// (Binding is ensured by -H 127.0.0.1 in package.json. This is browser-side hardening.)
const securityHeaders = [
  { key: 'X-Frame-Options', value: 'DENY' },
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  {
    key: 'Permissions-Policy',
    value: 'camera=(), microphone=(), geolocation=(), browsing-topics=(), interest-cohort=()',
  },
  { key: 'X-DNS-Prefetch-Control', value: 'off' },
  // These screens make no external requests, so by default lock everything down to self.
  // WebGL/Canvas use no external resources. dev is relaxed because HMR needs eval.
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

// When placed behind oauth2-proxy (reverse_proxy setup, pass_host_header=false), the upstream
// x-forwarded-host receives the internal IP:port instead of the real domain, and Server Actions'
// CSRF check (Origin match) rejects legitimate requests from the public domain.
// In that setup, explicitly allow the public domain via ISMS_SERVER_ACTIONS_ALLOWED_ORIGINS (comma-separated,
// e.g. "isms.example.com"). If unset, nothing extra is allowed.
const allowedOrigins = (process.env.ISMS_SERVER_ACTIONS_ALLOWED_ORIGINS ?? '')
  .split(',')
  .map((origin) => origin.trim())
  .filter((origin) => origin.length > 0);

const nextConfig: NextConfig = {
  async headers() {
    return [{ source: '/:path*', headers: securityHeaders }];
  },
  experimental: {
    serverActions: {
      allowedOrigins,
    },
  },
};

export default nextConfig;
