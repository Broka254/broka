// Send this store an order request (POST), as the signed-in buyer. Only
// what a buyer decides is passed on - products and quantities, how to hand
// over, contact and a note - never a price or a total: the API reads those
// from the listings. The browser's X-Idempotency-Key goes with it, so a
// retried tap returns the order the first one made.
import type { NextRequest } from 'next/server'

import { callApi, crossSite, readJson, respond, safeId } from '@/lib/session'

const KEY = /^[A-Za-z0-9_-]{8,64}$/

export async function POST(req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const refused = crossSite(req)
  if (refused) return refused
  const storeId = safeId((await params).id)
  const key = req.headers.get('x-idempotency-key') ?? ''
  const body = await readJson(req, 16_384)
  if (!storeId || !body || !KEY.test(key)) {
    return respond({ status: 400, data: { detail: { code: 'INVALID', message: 'This order could not be read. Reload the page.' } }, cookies: [] })
  }
  const items = (Array.isArray(body.items) ? body.items : []).slice(0, 20).map((raw) => {
    const i = (raw ?? {}) as Record<string, unknown>
    return { listing_id: typeof i.listing_id === 'string' ? i.listing_id.slice(0, 64) : '', quantity: Number(i.quantity) }
  })
  const str = (value: unknown, max: number) => (typeof value === 'string' && value.trim() ? value.slice(0, max) : undefined)
  const order = {
    store_id: storeId,
    items,
    fulfilment: body.fulfilment === 'collection' ? 'collection' : 'delivery',
    delivery_address: str(body.delivery_address, 300),
    contact_phone: str(body.contact_phone, 24),
    note: str(body.note, 500),
    surface: 'web',
    via: str(body.via, 32),
    campaign: typeof body.campaign === 'string' && /^[A-Za-z0-9_-]{8,32}$/.test(body.campaign) ? body.campaign : undefined,
  }
  return respond(await callApi(req, '/orders', { method: 'POST', body: order, idempotencyKey: key }))
}
