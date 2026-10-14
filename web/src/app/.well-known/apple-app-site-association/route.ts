// iOS Universal Links, for when there's an iOS build: APPLE_APP_IDS lists
// "<TeamID>.<bundle id>" entries, comma-separated.
export const dynamic = 'force-dynamic'

export function GET() {
  const appIDs = (process.env.APPLE_APP_IDS ?? '')
    .split(',')
    .map((id) => id.trim())
    .filter((id) => /^[A-Z0-9]{10}\.[A-Za-z0-9.-]+$/.test(id))
  if (!appIDs.length) return new Response('Not found', { status: 404 })
  return Response.json(
    { applinks: { details: [{ appIDs, components: [{ '/': '/store/*' }] }] } },
    { headers: { 'Cache-Control': 'public, max-age=3600' } },
  )
}
