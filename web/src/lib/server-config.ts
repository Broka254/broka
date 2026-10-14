// Settings only the server may read.
import 'server-only'

/**
 * The BROKA API: api.broka.co.ke, a custom domain on the Railway service.
 * Point elsewhere with BROKA_API_URL (a redeploy, no code change).
 */
export const API_URL = (
  process.env.BROKA_API_URL?.trim() || 'https://api.broka.co.ke'
).replace(/\/+$/, '')

/**
 * Shared with the API (its STOREFRONT_API_KEY). Proves to the API that a
 * forwarded store visit or share comes from this site, so it believes the
 * visitor address sent with it. Empty = not configured: the API then limits
 * forwarded counts by this site's own addresses.
 */
export function storefrontApiKey(): string {
  return process.env.STOREFRONT_API_KEY?.trim() ?? ''
}

/**
 * Shared with the BROKA website (its STOREFRONT_PROXY_KEY), which serves
 * broka.co.ke and passes the storefront's requests on here. Requests it
 * passes on arrive from the website's servers, so the platform's own
 * visitor headers may name the website rather than the visitor; the website
 * sends the visitor's address itself, with this key to prove it. Empty = not
 * configured: that header is ignored.
 */
export function storefrontProxyKey(): string {
  return process.env.STOREFRONT_PROXY_KEY?.trim() ?? ''
}
