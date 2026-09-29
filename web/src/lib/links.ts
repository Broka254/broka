// URLs the storefront builds: its own pages, links into the app, and link
// preview images.
import { ANDROID_PACKAGE, APP_DOWNLOAD_URL, SITE_URL } from './config'

export const storePath = (slug: string) => `/store/${encodeURIComponent(slug)}`

/** The store's "Store details" page (the app opens the same link). */
export const storeDetailsPath = (slug: string) => `${storePath(slug)}/about`

export const productPath = (slug: string, listingId: string) =>
  `${storePath(slug)}/p/${encodeURIComponent(listingId)}`

export const absoluteUrl = (path: string) => `${SITE_URL}${path}`

/** The 1200x630 JPEG link preview of an image (see app/og/[file]/route.ts). */
export const previewImageUrl = (assetId: string) => absoluteUrl(`/og/${assetId}.jpg`)

export const DEFAULT_PREVIEW_IMAGE = '/og-default.jpg'

/**
 * An Android "intent:" link that opens [url] in the BROKA app, or the APK
 * download when the app isn't installed. Chrome on Android follows these
 * whether or not the app's App Links are verified.
 */
export function androidAppLink(url: string, fallback: string = APP_DOWNLOAD_URL): string {
  const u = new URL(url)
  return (
    `intent://${u.host}${u.pathname}${u.search}` +
    `#Intent;scheme=https;package=${ANDROID_PACKAGE};` +
    `S.browser_fallback_url=${encodeURIComponent(fallback)};end`
  )
}

/** The ?via= tag of a URL's search params, if it's a plain short tag. */
export function viaTag(value: string | string[] | undefined): string | undefined {
  const v = Array.isArray(value) ? value[0] : value
  return v && /^[a-z0-9_-]{1,32}$/i.test(v) ? v.toLowerCase() : undefined
}
