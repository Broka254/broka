// The signed-in buyer's conversations with stores, newest first (GET
// ?user=<their id>, the id /api/stores/session gave the page): the website's
// inbox. Read from the inbox the BROKA app shows (GET /negotiate/inbox/{id},
// which answers 403 for anyone else's id) and cut down to the conversations
// a store page can open, with each one's store and product
// (lib/conversations.ts). Nothing here writes: reading the list marks
// nothing read.
//
// Not `dynamic = 'force-dynamic'` like its neighbours: that would make
// every store and product read below skip the data cache, and an inbox of
// forty threads would cost forty uncached reads of the API each time. The
// route is dynamic anyway - it reads the request's cookies - and its
// answers are never cached (respond sets no-store).
import { type NextRequest } from 'next/server'

import { getListing, getStore, getStoreById } from '@/lib/api'
import { conversationsFrom } from '@/lib/conversations'
import { API_URL } from '@/lib/server-config'
import { callApi, respond, safeId } from '@/lib/session'

export async function GET(req: NextRequest) {
  const user = safeId(req.nextUrl.searchParams.get('user'))
  if (!user) {
    return respond({ status: 400, data: { detail: { code: 'INVALID', message: 'Sign in again to see your messages.' } }, cookies: [] })
  }
  const result = await callApi(req, `/negotiate/inbox/${user}`)
  if (result.status < 200 || result.status >= 300) return respond(result)
  const data = await conversationsFrom(result.data, { getListing, getStore, getStoreById, apiUrl: API_URL })
  return respond({ ...result, data })
}
