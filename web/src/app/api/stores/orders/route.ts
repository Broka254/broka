// The signed-in buyer's orders (GET ?scope=open|closed|all&offset=).
import type { NextRequest } from 'next/server'

import { callApi, respond } from '@/lib/session'

export const dynamic = 'force-dynamic'

export async function GET(req: NextRequest) {
  const scope = req.nextUrl.searchParams.get('scope')
  const offset = Math.max(0, Math.floor(Number(req.nextUrl.searchParams.get('offset')) || 0))
  const q = new URLSearchParams({
    scope: scope === 'open' || scope === 'closed' ? scope : 'all',
    limit: '20',
    offset: String(offset),
  })
  return respond(await callApi(req, `/orders?${q}`))
}
