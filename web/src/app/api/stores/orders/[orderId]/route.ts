// One of the signed-in buyer's orders (GET). The API answers 404 for an
// order that isn't theirs; so does this.
import type { NextRequest } from 'next/server'

import { callApi, respond, safeId } from '@/lib/session'

export const dynamic = 'force-dynamic'

export async function GET(req: NextRequest, { params }: { params: Promise<{ orderId: string }> }) {
  const id = safeId((await params).orderId)
  if (!id) return respond({ status: 404, data: { detail: { code: 'ORDER_NOT_FOUND', message: 'Order not found' } }, cookies: [] })
  const result = await callApi(req, `/orders/${id}`)
  // Opening the order is reading its updates. Best-effort: the order shows
  // whether or not this lands. Skipped when the session was just renewed -
  // this request's cookies are the old ones - and done on the next poll.
  if (result.status === 200 && result.cookies.length === 0) {
    await callApi(req, '/orders/notifications/read', { method: 'POST', body: { order_id: id } })
  }
  return respond(result)
}
