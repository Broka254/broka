// Link-preview images: https://broka.co.ke/og/<image id>.jpg
//
// The API makes a 1200x630 JPEG of a store or product image (WhatsApp
// doesn't show WebP previews); this serves it from the site's own domain
// with long cache headers, so the CDN answers previews after the first.
import { API_URL } from '@/lib/server-config'

const FILE = /^([0-9a-f-]{36})\.jpg$/

export async function GET(_req: Request, { params }: { params: Promise<{ file: string }> }) {
  const { file } = await params
  const match = FILE.exec(file)
  if (!match) return new Response('Not found', { status: 404 })

  let upstream: Response
  try {
    upstream = await fetch(`${API_URL}/media/og/${match[1]}.jpg`, {
      signal: AbortSignal.timeout(25_000),
      cache: 'no-store',
    })
  } catch {
    return new Response('Preview unavailable', { status: 503, headers: { 'Retry-After': '30' } })
  }
  if (upstream.status === 404) return new Response('Not found', { status: 404 })
  if (!upstream.ok || !upstream.body) {
    return new Response('Preview unavailable', { status: 503, headers: { 'Retry-After': '30' } })
  }
  return new Response(upstream.body, {
    headers: {
      'Content-Type': 'image/jpeg',
      // An image id's preview never changes.
      'Cache-Control': 'public, max-age=86400, s-maxage=31536000, immutable',
    },
  })
}
