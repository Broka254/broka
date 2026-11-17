// A buyer's action on their order (POST). Only the buyer's own actions are
// passed on, each with only the fields it takes; the API decides whether
// the order allows it now. Nothing here can set a status or a price.
import type { NextRequest } from 'next/server'

import { callApi, crossSite, readJson, respond, safeId } from '@/lib/session'

type Shape = (body: Record<string, unknown>) => Record<string, unknown>

const text = (value: unknown, max: number) => (typeof value === 'string' ? value.slice(0, max) : undefined)

const ACTIONS: Record<string, { path: string; shape: Shape }> = {
  confirm: { path: 'confirm', shape: (b) => ({ revision: Number.isInteger(b.revision) ? b.revision : 0 }) },
  'reject-proposal': { path: 'reject-proposal', shape: (b) => ({ note: text(b.note, 300) }) },
  cancel: { path: 'cancel', shape: (b) => ({ reason: text(b.reason, 300) }) },
  received: { path: 'received', shape: () => ({}) },
  problem: { path: 'problem', shape: (b) => ({ note: text(b.note, 500) ?? '' }) },
  'payment-arrangement': {
    path: 'payment-arrangement',
    shape: (b) => ({
      arrangement: b.arrangement === 'independent_escrow' ? 'independent_escrow' : 'direct_to_seller',
      provider_id: b.arrangement === 'independent_escrow' ? text(b.provider_id, 40) : undefined,
    }),
  },
  'payment-reports': {
    path: 'payment-reports',
    shape: (b) => ({ kind: text(b.kind, 40), reference: text(b.reference, 64) || undefined, note: text(b.note, 300) || undefined }),
  },
}

export async function POST(req: NextRequest, { params }: { params: Promise<{ orderId: string; action: string }> }) {
  const refused = crossSite(req)
  if (refused) return refused
  const { orderId, action } = await params
  const id = safeId(orderId)
  const spec = ACTIONS[action]
  if (!id || !spec) {
    return respond({ status: 404, data: { detail: { code: 'NOT_FOUND', message: 'Not found' } }, cookies: [] })
  }
  const body = (await readJson(req)) ?? {}
  return respond(await callApi(req, `/orders/${id}/${spec.path}`, { method: 'POST', body: spec.shape(body) }))
}
