// Turning the API's image fields into something an <img> can load. The
// API's address is passed in by server code (lib/server-config.ts).
import type { ImageSizes } from './types'

/**
 * A loadable URL for an image value from the API:
 *  - absolute URLs (R2) as they are;
 *  - paths ("/media/i/...", images stored in the database) on the API;
 *  - data URIs as they are;
 *  - bare base64 (rows the media backfill hasn't converted yet) as a data URI.
 */
export function resolveImage(value: string | null | undefined, apiUrl: string): string | null {
  const v = value?.trim()
  if (!v) return null
  if (/^https?:\/\//i.test(v) || v.startsWith('data:')) return v
  if (v.startsWith('/')) return `${apiUrl}${v}`
  if (/^[A-Za-z0-9+/=\s]+$/.test(v) && v.length > 32) {
    const mime = v.startsWith('iVBOR') ? 'image/png' : v.startsWith('UklGR') ? 'image/webp' : 'image/jpeg'
    return `data:${mime};base64,${v.replace(/\s/g, '')}`
  }
  return null
}

/** The same image's sizes, resolved. */
export function resolveSizes(sizes: ImageSizes | null | undefined, apiUrl: string) {
  if (!sizes) return null
  const thumb = resolveImage(sizes.thumb, apiUrl)
  const medium = resolveImage(sizes.medium, apiUrl)
  const large = resolveImage(sizes.large, apiUrl)
  if (!thumb || !medium || !large) return null
  return { id: sizes.id, thumb, medium, large }
}

export type ResolvedSizes = NonNullable<ReturnType<typeof resolveSizes>>

/** srcset for the three sizes (480, 960 and 1600 px wide at most). */
export function srcSet(sizes: ResolvedSizes): string {
  return `${sizes.thumb} 480w, ${sizes.medium} 960w, ${sizes.large} 1600w`
}
