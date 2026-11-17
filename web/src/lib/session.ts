// A buyer's BROKA session on the web storefront, kept by this site's server.
import 'server-only'

// HOW THE WEBSITE SIGNS SOMEONE IN
// ================================
// With an SMS code, through the API's own sign-in (POST /auth/otp/sign-in/*):
// the same accounts as the app, the same tokens. The tokens never reach the
// page's JavaScript - they are httpOnly cookies scoped to /api/stores, the
// only paths that call the API on the buyer's behalf, so a script injected
// into a page has nothing to steal and the main website never receives
// them. Every call that changes something must also carry X-Broka-Web: 1,
// a header a cross-site page cannot add without a CORS preflight this site
// never grants (and the cookies are SameSite=Lax besides).
//
// The access token lasts 15 minutes (the API's ACCESS_TOKEN_EXPIRE_MINUTES);
// when it is missing or refused, the refresh token renews it once, here,
// and the new cookies ride back on the same response.
import { type NextRequest, NextResponse } from 'next/server'

import { visitorHeaders } from './forward'
import { API_URL } from './server-config'

export const ACCESS_COOKIE = 'broka_at'
export const REFRESH_COOKIE = 'broka_rt'
/** The verified-phone token between "code verified" and "account made". */
export const PHONE_COOKIE = 'broka_pv'

const COOKIE_PATH = '/api/stores'
const ACCESS_MAX_AGE = 15 * 60
const REFRESH_MAX_AGE = 30 * 24 * 60 * 60
const PHONE_MAX_AGE = 15 * 60
const TIMEOUT_MS = 25_000

export interface CookieChange {
  name: string
  value: string | null
  maxAge?: number
}

export interface ApiResult {
  status: number
  data: unknown
  cookies: CookieChange[]
}

const ID = /^[A-Za-z0-9-]{1,64}$/

/** An id safe to put in an API path. */
export function safeId(value: unknown): string | null {
  return typeof value === 'string' && ID.test(value) ? value : null
}

/** Refuse a state-changing call that did not come from this site's pages. */
export function crossSite(req: NextRequest): NextResponse | null {
  const site = req.headers.get('sec-fetch-site')
  if (req.headers.get('x-broka-web') !== '1' || (site && site !== 'same-origin' && site !== 'none')) {
    return NextResponse.json(
      { error: { code: 'CROSS_SITE', message: 'This request has to come from the store page.' } },
      { status: 403 },
    )
  }
  return null
}

/** The request body as an object, or null when it is not one. */
export async function readJson(req: Request, limit = 8192): Promise<Record<string, unknown> | null> {
  try {
    const text = await req.text()
    if (text.length > limit) return null
    const parsed: unknown = text ? JSON.parse(text) : {}
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : null
  } catch {
    return null
  }
}

function sessionCookies(access: string, refresh?: string | null): CookieChange[] {
  const out: CookieChange[] = [{ name: ACCESS_COOKIE, value: access, maxAge: ACCESS_MAX_AGE }]
  if (refresh) out.push({ name: REFRESH_COOKIE, value: refresh, maxAge: REFRESH_MAX_AGE })
  return out
}

export function signedIn(tokens: { access_token?: unknown; refresh_token?: unknown }): CookieChange[] {
  return typeof tokens.access_token === 'string'
    ? [...sessionCookies(tokens.access_token, typeof tokens.refresh_token === 'string' ? tokens.refresh_token : null),
       { name: PHONE_COOKIE, value: null }]
    : []
}

export function phoneVerified(token: string): CookieChange[] {
  return [{ name: PHONE_COOKIE, value: token, maxAge: PHONE_MAX_AGE }]
}

export const signedOut: CookieChange[] = [
  { name: ACCESS_COOKIE, value: null },
  { name: REFRESH_COOKIE, value: null },
  { name: PHONE_COOKIE, value: null },
]

/** The API's error, in the one shape the pages read: {error: {code, message}}. */
export function errorBody(status: number, data: unknown): { error: Record<string, unknown> } {
  const detail = (data as { detail?: unknown } | null)?.detail
  if (detail && typeof detail === 'object' && !Array.isArray(detail)) {
    const d = detail as Record<string, unknown>
    return { error: { ...d, code: d.code ?? `HTTP_${status}`, message: d.message ?? 'Something went wrong.' } }
  }
  if (typeof detail === 'string') return { error: { code: `HTTP_${status}`, message: detail } }
  if (Array.isArray(detail)) {
    return { error: { code: 'INVALID', message: 'Some of the details are not valid. Check them and try again.' } }
  }
  if (status === 429) return { error: { code: 'RATE_LIMITED', message: 'Too many tries. Wait a minute and try again.' } }
  return { error: { code: `HTTP_${status}`, message: 'BROKA could not do that just now. Try again.' } }
}

async function send(
  req: NextRequest,
  path: string,
  init: { method: string; body?: unknown; token?: string | null; idempotencyKey?: string | null },
): Promise<{ status: number; data: unknown }> {
  const headers: Record<string, string> = {
    Accept: 'application/json',
    'User-Agent': req.headers.get('user-agent') ?? '',
    // The visitor's own address, with the shared key, so the API's
    // per-address limits see the buyer rather than this server.
    ...visitorHeaders(req),
  }
  if (init.body !== undefined) headers['Content-Type'] = 'application/json'
  if (init.token) headers.Authorization = `Bearer ${init.token}`
  if (init.idempotencyKey) headers['X-Idempotency-Key'] = init.idempotencyKey
  const res = await fetch(`${API_URL}${path}`, {
    method: init.method,
    headers,
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
    signal: AbortSignal.timeout(TIMEOUT_MS),
    cache: 'no-store',
  })
  const text = await res.text()
  let data: unknown = null
  try {
    data = text ? JSON.parse(text) : null
  } catch {
    data = null
  }
  return { status: res.status, data }
}

async function refresh(req: NextRequest, refreshToken: string): Promise<CookieChange[] | null> {
  try {
    const r = await send(req, '/auth/token/refresh', { method: 'POST', body: { refresh_token: refreshToken } })
    if (r.status !== 200) return null
    const tokens = r.data as { access_token?: string; refresh_token?: string }
    return tokens.access_token ? sessionCookies(tokens.access_token, tokens.refresh_token) : null
  } catch {
    return null
  }
}

/**
 * Call the API. With `auth`, as the signed-in buyer: the access token from
 * the cookie, renewed once with the refresh token when it is missing or
 * refused. A network failure answers 503, never throws.
 */
export async function callApi(
  req: NextRequest,
  path: string,
  init: { method?: string; body?: unknown; auth?: boolean; idempotencyKey?: string | null } = {},
): Promise<ApiResult> {
  const method = init.method ?? 'GET'
  const auth = init.auth ?? true
  const cookies: CookieChange[] = []
  let token = auth ? req.cookies.get(ACCESS_COOKIE)?.value ?? null : null
  const refreshToken = auth ? req.cookies.get(REFRESH_COOKIE)?.value ?? null : null
  let renewed = false
  try {
    if (auth && !token && refreshToken) {
      const fresh = await refresh(req, refreshToken)
      renewed = true
      if (!fresh) return { status: 401, data: { detail: { code: 'SIGNED_OUT', message: 'Sign in to continue.' } }, cookies: signedOut }
      cookies.push(...fresh)
      token = fresh[0]!.value
    }
    if (auth && !token) {
      return { status: 401, data: { detail: { code: 'SIGNED_OUT', message: 'Sign in to continue.' } }, cookies }
    }
    let result = await send(req, path, { method, body: init.body, token, idempotencyKey: init.idempotencyKey })
    if (auth && result.status === 401 && refreshToken && !renewed) {
      const fresh = await refresh(req, refreshToken)
      if (!fresh) return { status: 401, data: { detail: { code: 'SIGNED_OUT', message: 'Sign in to continue.' } }, cookies: signedOut }
      cookies.push(...fresh)
      result = await send(req, path, { method, body: init.body, token: fresh[0]!.value, idempotencyKey: init.idempotencyKey })
    }
    if (auth && result.status === 401) return { ...result, cookies: [...cookies, ...signedOut] }
    return { ...result, cookies }
  } catch {
    return {
      status: 503,
      data: { detail: { code: 'API_UNREACHABLE', message: "Couldn't reach BROKA. Check your connection and try again." } },
      cookies,
    }
  }
}

/** A NextResponse for an API result: its data as-is on success, the one
 *  error shape otherwise, with any cookie changes applied. */
export function respond(result: ApiResult, shape?: (data: unknown) => unknown): NextResponse {
  const ok = result.status >= 200 && result.status < 300
  const body = ok ? (shape ? shape(result.data) : result.data) ?? {} : errorBody(result.status, result.data)
  return withCookies(NextResponse.json(body, { status: result.status }), result.cookies)
}

export function withCookies(res: NextResponse, changes: CookieChange[]): NextResponse {
  for (const c of changes) {
    if (c.value === null) {
      res.cookies.set(c.name, '', { path: COOKIE_PATH, httpOnly: true, sameSite: 'lax', secure: secure(), maxAge: 0 })
    } else {
      res.cookies.set(c.name, c.value, {
        path: COOKIE_PATH,
        httpOnly: true,
        sameSite: 'lax',
        secure: secure(),
        maxAge: c.maxAge,
      })
    }
  }
  res.headers.set('Cache-Control', 'no-store')
  return res
}

function secure(): boolean {
  return process.env.NODE_ENV === 'production'
}
