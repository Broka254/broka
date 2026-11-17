// A product went into this browser's cart: interest for the store owner's
// order funnel, counted once per visitor and product per half hour by the
// API (which also skips crawlers and the owner). Never an order.
import { forwardToApi } from '@/lib/forward'

export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  return forwardToApi(req, id, 'cart-events', (body) => ({
    surface: 'web',
    listing_id: typeof body.listing_id === 'string' ? body.listing_id.slice(0, 64) : '',
    via: typeof body.via === 'string' ? body.via.slice(0, 32) : undefined,
    visitor: typeof body.visitor === 'string' ? body.visitor.slice(0, 64) : undefined,
  }))
}
