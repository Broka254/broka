// The browser's calls to this site's own /api/stores routes - the only API
// the pages talk to. Every call that changes something carries the header
// the server checks to refuse cross-site requests (lib/session.ts), and
// every failure comes back as one shape, so a page shows a sentence and
// never a stack trace or a lost form.

export interface WebError {
  code: string
  message: string
  [key: string]: unknown
}

export type WebResult<T> =
  | { ok: true; status: number; data: T }
  | { ok: false; status: number; error: WebError }

const OFFLINE: WebError = {
  code: 'NETWORK',
  message: "Couldn't reach BROKA - check your connection. Nothing was lost; try again.",
}

export async function webFetch<T = unknown>(
  path: string,
  init: { method?: 'GET' | 'POST' | 'DELETE'; body?: unknown; idempotencyKey?: string } = {},
): Promise<WebResult<T>> {
  const method = init.method ?? 'GET'
  const headers: Record<string, string> = { Accept: 'application/json' }
  if (method !== 'GET') headers['X-Broka-Web'] = '1'
  if (init.body !== undefined) headers['Content-Type'] = 'application/json'
  if (init.idempotencyKey) headers['X-Idempotency-Key'] = init.idempotencyKey
  let res: Response
  try {
    res = await fetch(path, {
      method,
      headers,
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
      credentials: 'same-origin',
      cache: 'no-store',
    })
  } catch {
    return { ok: false, status: 0, error: OFFLINE }
  }
  let data: unknown = null
  try {
    data = await res.json()
  } catch {
    data = null
  }
  if (res.ok) return { ok: true, status: res.status, data: data as T }
  const error = (data as { error?: WebError } | null)?.error
  return {
    ok: false,
    status: res.status,
    error: error && typeof error.message === 'string'
      ? error
      : { code: `HTTP_${res.status}`, message: 'BROKA could not do that just now. Try again.' },
  }
}

/** A fresh key for one attempt at one request (X-Idempotency-Key). */
export function newKey(): string {
  try {
    return crypto.randomUUID().replace(/-/g, '')
  } catch {
    return `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 12)}`
  }
}
