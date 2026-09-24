// A share-button tap on the web storefront, counted for the store owner.
import { forwardToApi } from '@/lib/forward'

export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  return forwardToApi(req, id, 'share', (body) => ({
    surface: 'web',
    channel: typeof body.channel === 'string' ? body.channel.slice(0, 32) : 'other',
  }))
}
