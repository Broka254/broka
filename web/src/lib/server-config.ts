// Settings only the server may read.
import 'server-only'

/**
 * The BROKA API: the Azure Container App. Render (broka-dbjd.onrender.com)
 * stays up as the fallback; switch back with BROKA_API_URL (a redeploy, no
 * code change).
 */
export const API_URL = (
  process.env.BROKA_API_URL?.trim() || 'https://broka-api.redhill-7a4b8acc.southafricanorth.azurecontainerapps.io'
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
