type Environment = Record<string, string | undefined>;

export function hasIdentityProvisioningConfiguration(environment: Environment): boolean {
  if (environment.IDENTITY_PROVISIONING_PROVIDER !== 'google_workspace') return false;
  const token = environment.IDENTITY_PROVISIONING_DISPATCH_TOKEN;
  if (!token || token !== token.trim() || token.length < 32) return false;

  try {
    const url = new URL(environment.IDENTITY_PROVISIONING_DISPATCH_URL ?? '');
    const allowedOrigin = new URL(environment.IDENTITY_PROVISIONING_ALLOWED_ORIGIN ?? '');
    return url.protocol === 'https:'
      && Boolean(url.hostname)
      && !url.username
      && !url.password
      && !url.search
      && !url.hash
      && url.pathname === '/v1/provisioning/requests'
      && allowedOrigin.protocol === 'https:'
      && allowedOrigin.pathname === '/'
      && !allowedOrigin.username
      && !allowedOrigin.password
      && !allowedOrigin.search
      && !allowedOrigin.hash
      && url.origin === allowedOrigin.origin;
  } catch {
    return false;
  }
}
