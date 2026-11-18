// A signed-in buyer's conversation with a store, or about one of its
// products: read it (GET ?listing=) and ask (POST {content, listing_id?}).
// The same conversation as in the BROKA app - this reads the app's own
// thread endpoints and writes through the API's rate-limited enquiry route.
import { type NextRequest } from 'next/server'

import { callApi, crossSite, readJson, respond, safeId } from '@/lib/session'

export const dynamic = 'force-dynamic'

interface ThreadMessage {
  id: string | null
  role: 'buyer' | 'seller'
  content: string
  kind: string
  created_at: string | null
  client_msg_id?: string
}

const CLIENT_ID = /^[A-Za-z0-9_-]{8,64}$/

/** Only the direct conversation: no private notes from Zeno, and media as
 *  a mention (the app shows photos and voice notes). The buyer's own
 *  messages keep the id their browser sent them with, so the page can tell
 *  the stored copy of a message it is still showing as "Sending…" from a
 *  second one (EnquiryThread.tsx). */
function thread(data: unknown): { messages: ThreadMessage[] } {
  const rows = Array.isArray(data) ? data : []
  const messages: ThreadMessage[] = []
  for (const raw of rows) {
    const m = (raw ?? {}) as Record<string, unknown>
    const role = m.role
    if (m.via_ai === true || (role !== 'buyer' && role !== 'seller')) continue
    const kind = typeof m.msg_type === 'string' ? m.msg_type : 'text'
    if (kind === 'deleted' || kind === 'call') continue
    messages.push({
      id: typeof m.id === 'string' ? m.id : null,
      role,
      content: kind === 'text' ? String(m.content ?? '') : '',
      kind,
      created_at: typeof m.created_at === 'string' ? m.created_at : null,
      ...(role === 'buyer' && typeof m.client_msg_id === 'string' && CLIENT_ID.test(m.client_msg_id)
        ? { client_msg_id: m.client_msg_id }
        : {}),
    })
  }
  return { messages }
}

export async function GET(req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const storeId = safeId((await params).id)
  const listing = req.nextUrl.searchParams.get('listing')
  const listingId = listing ? safeId(listing) : null
  if (!storeId || (listing && !listingId)) {
    return respond({ status: 404, data: { detail: { code: 'NOT_FOUND', message: 'Not found' } }, cookies: [] })
  }
  const path = listingId ? `/negotiate/${listingId}/history` : `/negotiate/store/${storeId}/history`
  return respond(await callApi(req, path), thread)
}

export async function POST(req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const refused = crossSite(req)
  if (refused) return refused
  const storeId = safeId((await params).id)
  const body = await readJson(req)
  if (!storeId || !body) {
    return respond({ status: 400, data: { detail: { code: 'INVALID', message: 'Write your question first.' } }, cookies: [] })
  }
  const content = typeof body.content === 'string' ? body.content.slice(0, 2000) : ''
  const listingId = body.listing_id ? safeId(body.listing_id) : null
  const clientId = typeof body.client_msg_id === 'string' && CLIENT_ID.test(body.client_msg_id)
    ? body.client_msg_id : undefined
  return respond(await callApi(req, `/stores/${storeId}/enquiries`, {
    method: 'POST',
    body: { content, listing_id: listingId ?? undefined, client_msg_id: clientId },
  }))
}
