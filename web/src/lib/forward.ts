// Passing the storefront's visit and share counts on to the API.
import 'server-only'

import { timingSafeEqual } from 'node:crypto'

import { API_URL, storefrontApiKey, storefrontProxyKey } from './server-config'

const ID = /^[A-Za-z0-9-]{1,64}$/
const MAX_BODY = 2048

const IPV4 = /^(\d{1,3}\.){3}\d{1,3}$/
const IPV6 = /^[0-9a-f:.]+$/i

/** Headers the BROKA website adds to the requests it passes on here. */
const PROXY_KEY_HEADER = 'x-broka-proxy-key'
const PROXY_VISITOR_HEADER = 'x-broka-visitor-ip'

function fromWebsite(req: Request): boolean {
  const expected = storefrontProxyKey()
  const given = req.headers.get(PROXY_KEY_HEADER)
  if (!expected || !given) return false
  const a = Buffer.from(given)
  const b = Buffer.from(expected)
  return a.length === b.length && timingSafeEqual(a, b)
}

/**
 * The visitor's address. On broka.co.ke the BROKA website passes these
 * requests on from its own servers, so the platform's headers may name the
 * website, and every web visitor would look like one client to the API's
 * per-visitor limits; the website sends the visitor's address itself, with
 * the shared key. Otherwise (the storefront opened at its own address),
 * Vercel sets x-real-ip and x-forwarded-for itself (overwriting anything the
 * visitor sent), so the first entry is the visitor. Anything that doesn't
 * look like an address is dropped; the API validates it again.
 */
export function visitorAddress(req: Request): string | null {
  const candidates = fromWebsite(req)
    ? [req.headers.get(PROXY_VISITOR_HEADER)]
    : [req.headers.get('x-real-ip'), req.headers.get('x-forwarded-for')?.split(',')[0]]
  for (const raw of candidates) {
    const value = raw?.trim()
    if (value && value.length <= 45 && (IPV4.test(value) || (value.includes(':') && IPV6.test(value)))) {
      return value
    }
  }
  return null
}

/**
 * Headers that tell the API which visitor this is. Sent only with the
 * shared key: without it the API ignores the address anyway, and there's no
 * reason to pass visitors' addresses on for nothing.
 */
export function visitorHeaders(req: Request): Record<string, string> {
  const key = storefrontApiKey()
  if (!key) return {}
  const address = visitorAddress(req)
  return address ? { 'X-Broka-Storefront-Key': key, 'X-Broka-Client-IP': address } : {}
}

export async function forwardToApi(
  req: Request,
  storeId: string,
  action: 'visit' | 'share',
  shape: (body: Record<string, unknown>) => Record<string, unknown>,
): Promise<Response> {
  if (!ID.test(storeId)) return new Response(null, { status: 400 })
  let body: Record<string, unknown> = {}
  try {
    const text = await req.text()
    if (text.length > MAX_BODY) return new Response(null, { status: 413 })
    const parsed: unknown = text ? JSON.parse(text) : {}
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) body = parsed as Record<string, unknown>
  } catch {
    return new Response(null, { status: 400 })
  }
  try {
    const res = await fetch(`${API_URL}/stores/${storeId}/${action}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'User-Agent': req.headers.get('user-agent') ?? '',
        ...visitorHeaders(req),
      },
      body: JSON.stringify(shape(body)),
      signal: AbortSignal.timeout(10_000),
      cache: 'no-store',
    })
    return new Response(null, { status: res.ok ? 204 : res.status })
  } catch {
    // Counting never matters enough to show the visitor an error.
    return new Response(null, { status: 202 })
  }
}
