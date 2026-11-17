// Shared by the store-order tests: answering fetch by address, and an order
// as the API returns it (backend api/domains/store_orders/).
import { vi } from 'vitest'

import type { Order } from '@/lib/orders'
import type { Store } from '@/lib/types'

/** A whole store as the API sends it, so a page renders as it would live. */
export const storeFixture = (over: Partial<Store> = {}): Store => ({
  id: 's1',
  name: 'Clanix',
  slug: 'clanix',
  url: 'https://broka.co.ke/store/clanix',
  category: 'Electronics',
  description: 'Genuine phones and accessories.',
  country: 'Kenya',
  county: 'Nairobi',
  subcounty: 'Starehe',
  location_description: null,
  business_email: null,
  business_email_verified: false,
  logo: null,
  cover: null,
  photo_images: [],
  logo_url: null,
  photos: [],
  owner: {
    name: 'Jane Wanjiru',
    verified: true,
    rating: 4.8,
    review_count: 12,
    completed_deals: 12,
    member_since: '2025-01-10T00:00:00',
  },
  is_active: true,
  listing_count: 1,
  ...over,
})

export const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })

export interface Call {
  url: string
  method: string
  /** Lower-cased header names. */
  headers: Record<string, string>
  body: unknown
}

type Answer = (call: Call) => Response | Promise<Response>

/**
 * Answers fetch from a table of address -> response. An address matches the
 * start of the URL; the longest wins. Anything not in the table answers 599,
 * so a call the test did not expect shows up as an error, not a hang.
 */
export function stubFetch(routes: Record<string, Answer | Response>) {
  const calls: Call[] = []
  const keys = Object.keys(routes).sort((a, b) => b.length - a.length)
  const fn = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input)
    const call: Call = {
      url,
      method: (init?.method ?? 'GET').toUpperCase(),
      headers: Object.fromEntries(new Headers(init?.headers).entries()),
      body: typeof init?.body === 'string' ? JSON.parse(init.body) : undefined,
    }
    calls.push(call)
    const key = keys.find((k) => url === k || url.startsWith(k))
    if (!key) return json({ error: { code: 'UNSTUBBED', message: `Nothing stubbed for ${url}` } }, 599)
    const answer = routes[key]!
    return typeof answer === 'function' ? answer(call) : answer.clone()
  })
  vi.stubGlobal('fetch', fn)
  return {
    calls,
    fn,
    /** The calls made to addresses starting with [prefix], in order. */
    to: (prefix: string, method?: string) =>
      calls.filter((c) => c.url.startsWith(prefix) && (!method || c.method === method)),
  }
}

export const SIGNED_IN = { signed_in: true, user: { id: 'u1', name: 'Amina Wanjiru', phone: '+254712345678' } }

/** An order waiting on the buyer to confirm the store's offer. */
export function order(over: Partial<Order> = {}): Order {
  return {
    id: 'o1',
    reference: 'BK-1001',
    role: 'buyer',
    status: 'awaiting_buyer_confirmation',
    status_label: 'Waiting for your confirmation',
    open: true,
    store: { id: 's1', name: 'Clanix', slug: 'clanix', url: 'https://broka.co.ke/store/clanix' },
    currency: 'KES',
    items: [
      {
        id: 'i1',
        listing_id: 'l1',
        name: 'Samsung A15',
        price_unit: null,
        image: null,
        requested_quantity: 2,
        requested_unit_price_minor: 1_500_000,
        requested_line_total_minor: 3_000_000,
        proposed_quantity: 1,
        proposed_unit_price_minor: 1_500_000,
        final_quantity: null,
        final_unit_price_minor: null,
        quantity: 1,
        unit_price_minor: 1_500_000,
        line_total_minor: 1_500_000,
        changed: true,
        removed: false,
      },
    ],
    totals: {
      requested_subtotal_minor: 3_000_000,
      seller_subtotal_minor: 1_500_000,
      delivery_fee_minor: 30_000,
      total_minor: 1_530_000,
      display_total_minor: 1_530_000,
      final: false,
    },
    fulfilment: {
      method: 'delivery',
      requested_method: 'delivery',
      address: 'Kilimani, opposite Yaya Centre',
      contact_phone: '+254712345678',
      note: null,
      dispatch_note: null,
    },
    buyer_note: null,
    seller_note: 'Only one in stock.',
    decline_reason: null,
    cancel_reason: null,
    cancelled_by: null,
    problem: null,
    revision: 2,
    expires_at: null,
    expires_in_seconds: null,
    expiry_stage: null,
    allowed_actions: ['confirm', 'reject_proposal', 'cancel'],
    payment: {
      arrangement: null,
      arrangement_label: null,
      provider: null,
      reports: [],
      summary: {
        label: 'No payment reported yet',
        awaiting_external_confirmation: false,
        status_note: null,
        verified: false,
      },
      can_choose: true,
      allowed_reports: [],
      notice:
        'BROKA does not receive, hold, verify or release payments for store orders. These are reports made by the buyer or the store, not confirmations from BROKA or from any payment provider.',
    },
    events: [
      {
        id: 'e1',
        kind: 'submitted',
        label: 'Order request sent',
        actor_role: 'buyer',
        from_status: null,
        to_status: 'submitted',
        revision: 1,
        detail: null,
        created_at: '2026-11-17T08:00:00+00:00',
      },
    ],
    created_at: '2026-11-17T08:00:00+00:00',
    updated_at: '2026-11-17T08:05:00+00:00',
    ...over,
  }
}
