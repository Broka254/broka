// Passing the storefront's visit and share counts on to the API.
import 'server-only'

import { API_URL } from './server-config'

const ID = /^[A-Za-z0-9-]{1,64}$/
const MAX_BODY = 2048

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
