// A store visit from the web storefront, passed on to the API with the
// visitor's own user agent (the API skips crawlers).
import { forwardToApi } from '@/lib/forward'

export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  return forwardToApi(req, id, 'visit', (body) => ({
    surface: 'web',
    via: typeof body.via === 'string' ? body.via.slice(0, 32) : undefined,
    referrer: typeof body.referrer === 'string' ? body.referrer.slice(0, 500) : undefined,
    visitor: typeof body.visitor === 'string' ? body.visitor.slice(0, 64) : undefined,
    // Only the shape the API accepts; an unknown token is ignored there,
    // and the campaign is credited only if the visit itself counted.
    campaign:
      typeof body.campaign === 'string' && /^[A-Za-z0-9_-]{8,32}$/.test(body.campaign)
        ? body.campaign
        : undefined,
  }))
}
