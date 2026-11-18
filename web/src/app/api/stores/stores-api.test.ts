// @vitest-environment node
//
// The storefront's own API (/api/stores/...): signing a buyer in, keeping
// their session, and passing their orders and questions to the BROKA API.
// The browser must never hold a token, must never name a price or a status,
// and a page on another site must never be able to act for the buyer.
import { NextRequest } from 'next/server'
import { afterEach, describe, expect, it, vi } from 'vitest'

import { PRIVACY_VERSION, TERMS_VERSION } from '@/lib/legal'
import { API_URL } from '@/lib/server-config'
import { json, stubFetch } from '@/test/fixtures'

import { POST as cartEvent } from './[id]/cart-events/route'
import { GET as readThread, POST as askStore } from './[id]/enquiries/route'
import { GET as listConversations } from './conversations/route'
import { POST as submitOrder } from './[id]/orders/route'
import { GET as listOrders } from './orders/route'
import { GET as readOrder } from './orders/[orderId]/route'
import { POST as orderAction } from './orders/[orderId]/[action]/route'
import { POST as createAccount } from './session/account/route'
import { POST as sendCode } from './session/code/route'
import { DELETE as signOut, GET as readSession } from './session/route'
import { POST as verifyCode } from './session/verify/route'

const api = (path: string) => `${API_URL}${path}`

/** What a page on this site adds to a request that changes something. */
const FROM_PAGE = { 'x-broka-web': '1' }

function request(
  path: string,
  init: { method?: string; body?: unknown; headers?: Record<string, string>; cookies?: Record<string, string> } = {},
) {
  const headers: Record<string, string> = { ...init.headers }
  if (init.cookies) headers.cookie = Object.entries(init.cookies).map(([k, v]) => `${k}=${v}`).join('; ')
  if (init.body !== undefined) headers['content-type'] = 'application/json'
  return new NextRequest(`https://broka.co.ke${path}`, {
    method: init.method ?? (init.body === undefined ? 'GET' : 'POST'),
    headers,
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  })
}

const ctx = <T,>(params: T) => ({ params: Promise.resolve(params) })

const setCookies = (res: Response) => res.headers.getSetCookie()
const cookie = (res: Response, name: string) => setCookies(res).find((c) => c.startsWith(`${name}=`))

afterEach(() => vi.unstubAllGlobals())

describe('who is signed in', () => {
  it('answers "signed out" without calling the API when there is no session', async () => {
    const { fn } = stubFetch({})
    const res = await readSession(request('/api/stores/session'))
    expect(await res.json()).toEqual({ signed_in: false })
    expect(fn).not.toHaveBeenCalled()
  })

  it("gives the page the buyer's name and number and nothing else of the account", async () => {
    const { to } = stubFetch({
      [api('/auth/me')]: json({ id: 'u1', name: 'Amina', phone: '+254712345678', email: 'a@b.co', password_hash: 'x' }),
    })
    const res = await readSession(request('/api/stores/session', { cookies: { broka_at: 'tok' } }))
    expect(await res.json()).toEqual({ signed_in: true, user: { id: 'u1', name: 'Amina', phone: '+254712345678' } })
    expect(to(api('/auth/me'))[0]!.headers.authorization).toBe('Bearer tok')
  })

  it('renews an expired access token once with the refresh cookie, and passes the new cookies on', async () => {
    const { to } = stubFetch({
      [api('/auth/me')]: (c) =>
        c.headers.authorization === 'Bearer old'
          ? json({ detail: 'Could not validate credentials' }, 401)
          : json({ id: 'u1', name: 'Amina', phone: '+254712345678' }),
      [api('/auth/token/refresh')]: json({ access_token: 'new', refresh_token: 'r2' }),
    })
    const res = await readSession(request('/api/stores/session', { cookies: { broka_at: 'old', broka_rt: 'r1' } }))
    expect(await res.json()).toMatchObject({ signed_in: true })
    expect(to(api('/auth/token/refresh'))).toHaveLength(1)
    expect(to(api('/auth/token/refresh'))[0]!.body).toEqual({ refresh_token: 'r1' })
    expect(cookie(res, 'broka_at')).toContain('broka_at=new')
    expect(cookie(res, 'broka_rt')).toContain('broka_rt=r2')
  })

  it('renews first when only the refresh cookie is left (the access cookie lasts 15 minutes)', async () => {
    const { calls } = stubFetch({
      [api('/auth/me')]: json({ id: 'u1', name: 'Amina', phone: '+254712345678' }),
      [api('/auth/token/refresh')]: json({ access_token: 'fresh' }),
    })
    const res = await readSession(request('/api/stores/session', { cookies: { broka_rt: 'r1' } }))
    expect(await res.json()).toMatchObject({ signed_in: true })
    expect(calls.map((c) => c.url)).toEqual([api('/auth/token/refresh'), api('/auth/me')])
    expect(calls[1]!.headers.authorization).toBe('Bearer fresh')
  })

  it('signs the buyer out of the page, and clears every cookie, when the refresh token is refused', async () => {
    stubFetch({
      [api('/auth/me')]: json({ detail: 'expired' }, 401),
      [api('/auth/token/refresh')]: json({ detail: 'Refresh token has been revoked' }, 401),
    })
    const res = await readSession(request('/api/stores/session', { cookies: { broka_at: 'old', broka_rt: 'revoked' } }))
    expect(await res.json()).toEqual({ signed_in: false })
    for (const name of ['broka_at', 'broka_rt', 'broka_pv']) expect(cookie(res, name)).toMatch(/Max-Age=0/i)
  })

  it('tells the page when BROKA cannot be reached, rather than that the buyer is signed out', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => { throw new TypeError('network down') }))
    const res = await readSession(request('/api/stores/session', { cookies: { broka_at: 'tok' } }))
    expect(res.status).toBe(503)
    expect(await res.json()).toMatchObject({ signed_in: false, error: { code: 'API_UNREACHABLE' } })
  })

  it('signing out ends the session on the API too, and clears the cookies', async () => {
    const { to } = stubFetch({ [api('/auth/token/revoke')]: new Response(null, { status: 204 }) })
    const res = await signOut(
      request('/api/stores/session', { method: 'DELETE', headers: FROM_PAGE, cookies: { broka_at: 'a', broka_rt: 'r1' } }),
    )
    expect(await res.json()).toEqual({ signed_in: false })
    expect(to(api('/auth/token/revoke'))[0]!.body).toEqual({ refresh_token: 'r1' })
    expect(to(api('/auth/token/revoke'))[0]!.headers.authorization).toBeUndefined()
    for (const name of ['broka_at', 'broka_rt', 'broka_pv']) expect(cookie(res, name)).toMatch(/Max-Age=0/i)
  })
})

describe('a page on another site cannot act for the buyer', () => {
  const mutating: Array<[string, () => Promise<Response>]> = [
    ['send a code', () => sendCode(request('/api/stores/session/code', { body: { phone: '0712345678' } }))],
    ['verify a code', () => verifyCode(request('/api/stores/session/verify', { body: { phone: '0712345678', code: '123456' } }))],
    ['create an account', () => createAccount(request('/api/stores/session/account', { body: { name: 'Amina' }, cookies: { broka_pv: 'tok' } }))],
    ['sign out', () => signOut(request('/api/stores/session', { method: 'DELETE', cookies: { broka_rt: 'r' } }))],
    [
      'send an order',
      () => submitOrder(request('/api/stores/s1/orders', { body: { items: [] }, headers: { 'x-idempotency-key': 'abcdefgh12' }, cookies: { broka_at: 't' } }), ctx({ id: 's1' })),
    ],
    ['confirm an order', () => orderAction(request('/api/stores/orders/o1/confirm', { body: { revision: 1 }, cookies: { broka_at: 't' } }), ctx({ orderId: 'o1', action: 'confirm' }))],
    ['ask a store', () => askStore(request('/api/stores/s1/enquiries', { body: { content: 'Hello' }, cookies: { broka_at: 't' } }), ctx({ id: 's1' }))],
  ]

  it.each(mutating)("refuses to %s without the header only this site's pages send", async (_name: string, call: () => Promise<Response>) => {
    const { fn } = stubFetch({})
    const res = await call()
    expect(res.status).toBe(403)
    expect(await res.json()).toMatchObject({ error: { code: 'CROSS_SITE' } })
    expect(fn).not.toHaveBeenCalled()
  })

  it('refuses a request the browser says came from another site, even with the header', async () => {
    const { fn } = stubFetch({})
    const res = await sendCode(
      request('/api/stores/session/code', { body: { phone: '0712345678' }, headers: { ...FROM_PAGE, 'sec-fetch-site': 'cross-site' } }),
    )
    expect(res.status).toBe(403)
    expect(fn).not.toHaveBeenCalled()
  })

  it('accepts a request from this site, and one typed straight into the address bar', async () => {
    stubFetch({ [api('/auth/otp/sign-in/request')]: json({ ok: true, account_exists: false }) })
    for (const site of ['same-origin', 'none']) {
      const res = await sendCode(
        request('/api/stores/session/code', { body: { phone: '0712345678' }, headers: { ...FROM_PAGE, 'sec-fetch-site': site } }),
      )
      expect(res.status).toBe(200)
    }
  })
})

describe('signing in with a code', () => {
  it('asks the API for a code and passes on only what the page needs', async () => {
    const { to } = stubFetch({
      [api('/auth/otp/sign-in/request')]: json({
        ok: true, phone: '+254712345678', account_exists: true, expires_in_seconds: 300, debug_code: '123456', internal: 'x',
      }),
    })
    const res = await sendCode(request('/api/stores/session/code', { body: { phone: ' 0712345678 ' }, headers: FROM_PAGE }))
    expect(to(api('/auth/otp/sign-in/request'))[0]!.body).toEqual({ phone: '0712345678' })
    expect(await res.json()).toEqual({
      phone: '+254712345678', account_exists: true, expires_in_seconds: 300, debug_code: '123456',
    })
  })

  it('sends no debug code unless the API sent one - production SMS never does', async () => {
    stubFetch({ [api('/auth/otp/sign-in/request')]: json({ ok: true, phone: '+254712345678', account_exists: false }) })
    const res = await sendCode(request('/api/stores/session/code', { body: { phone: '0712345678' }, headers: FROM_PAGE }))
    expect(await res.json()).not.toHaveProperty('debug_code')
  })

  it('needs a phone number, and tells the buyer when they have asked too often', async () => {
    const { fn } = stubFetch({ [api('/auth/otp/sign-in/request')]: json({}, 429) })
    const none = await sendCode(request('/api/stores/session/code', { body: { phone: '  ' }, headers: FROM_PAGE }))
    expect(none.status).toBe(400)
    expect(fn).not.toHaveBeenCalled()
    const many = await sendCode(request('/api/stores/session/code', { body: { phone: '0712345678' }, headers: FROM_PAGE }))
    expect(many.status).toBe(429)
    expect(await many.json()).toMatchObject({ error: { code: 'RATE_LIMITED' } })
  })

  it('signs an existing account in: the tokens go to httpOnly cookies and never into the page', async () => {
    stubFetch({
      [api('/auth/otp/sign-in/verify')]: json({
        ok: true, account_exists: true, access_token: 'ACCESS-TOKEN', refresh_token: 'REFRESH-TOKEN',
        user_id: 'u1', name: 'Amina', phone: '+254712345678',
      }),
    })
    const res = await verifyCode(
      request('/api/stores/session/verify', { body: { phone: '0712345678', code: '12 34 56' }, headers: FROM_PAGE }),
    )
    const body = JSON.stringify(await res.json())
    expect(body).toContain('"signed_in":true')
    expect(body).not.toContain('ACCESS-TOKEN')
    expect(body).not.toContain('REFRESH-TOKEN')
    for (const [name, value] of [['broka_at', 'ACCESS-TOKEN'], ['broka_rt', 'REFRESH-TOKEN']]) {
      const c = cookie(res, name!)!
      expect(c).toContain(`${name}=${value}`)
      expect(c).toMatch(/HttpOnly/i)
      expect(c).toMatch(/SameSite=lax/i)
      expect(c).toContain('Path=/api/stores')
    }
  })

  it('sends the code without spaces, as the API checks it', async () => {
    const { to } = stubFetch({ [api('/auth/otp/sign-in/verify')]: json({ detail: 'Invalid or expired code' }, 400) })
    await verifyCode(request('/api/stores/session/verify', { body: { phone: '0712345678', code: '12 34 56' }, headers: FROM_PAGE }))
    expect(to(api('/auth/otp/sign-in/verify'))[0]!.body).toEqual({ phone: '0712345678', code: '123456' })
  })

  it('a wrong code signs nobody in and sets no cookie', async () => {
    stubFetch({ [api('/auth/otp/sign-in/verify')]: json({ detail: 'Invalid or expired code' }, 400) })
    const res = await verifyCode(request('/api/stores/session/verify', { body: { phone: '0712345678', code: '000000' }, headers: FROM_PAGE }))
    expect(res.status).toBe(400)
    expect(await res.json()).toEqual({ error: { code: 'HTTP_400', message: 'Invalid or expired code' } })
    expect(setCookies(res)).toEqual([])
  })

  it('a new number keeps only a short-lived proof of the phone, then asks for an account', async () => {
    stubFetch({ [api('/auth/otp/sign-in/verify')]: json({ ok: true, account_exists: false, phone_verify_token: 'PHONE-PROOF-0123456789' }) })
    const res = await verifyCode(request('/api/stores/session/verify', { body: { phone: '0722000111', code: '123456' }, headers: FROM_PAGE }))
    expect(await res.json()).toEqual({ signed_in: false, needs_account: true })
    const c = cookie(res, 'broka_pv')!
    expect(c).toContain('broka_pv=PHONE-PROOF-0123456789')
    expect(c).toMatch(/HttpOnly/i)
    expect(c).toMatch(/Max-Age=900/i)
    expect(cookie(res, 'broka_at')).toBeUndefined()
  })

  it('cookies are Secure in production', async () => {
    vi.stubEnv('NODE_ENV', 'production')
    stubFetch({ [api('/auth/otp/sign-in/verify')]: json({ ok: true, account_exists: true, access_token: 'a', refresh_token: 'r', user_id: 'u1' }) })
    const res = await verifyCode(request('/api/stores/session/verify', { body: { phone: '0712345678', code: '123456' }, headers: FROM_PAGE }))
    expect(cookie(res, 'broka_at')).toMatch(/Secure/i)
  })
})

describe('creating the account for a verified number', () => {
  const ticked = { name: ' Amina Wanjiru ', age_confirmed: true, terms_accepted: true, privacy_acknowledged: true }

  it('needs the proof of the phone from the step before', async () => {
    const { fn } = stubFetch({})
    const res = await createAccount(request('/api/stores/session/account', { body: ticked, headers: FROM_PAGE }))
    expect(res.status).toBe(400)
    expect(await res.json()).toMatchObject({ error: { code: 'PHONE_NOT_VERIFIED' } })
    expect(fn).not.toHaveBeenCalled()
  })

  it('sends exactly what the buyer ticked, with the revisions of the documents the page showed', async () => {
    const { to } = stubFetch({
      [api('/auth/otp/sign-in/register')]: json({ user_id: 'u9', name: 'Amina Wanjiru', phone: '+254722000111', access_token: 'A', refresh_token: 'R' }, 201),
    })
    const res = await createAccount(
      request('/api/stores/session/account', { body: ticked, headers: FROM_PAGE, cookies: { broka_pv: 'PHONE-PROOF-0123456789' } }),
    )
    expect(to(api('/auth/otp/sign-in/register'))[0]!.body).toEqual({
      phone_verify_token: 'PHONE-PROOF-0123456789',
      name: 'Amina Wanjiru',
      legal_acceptance: {
        age_confirmed: true,
        terms_accepted: true,
        privacy_acknowledged: true,
        terms_version: TERMS_VERSION,
        privacy_version: PRIVACY_VERSION,
      },
    })
    expect(await res.json()).toEqual({ signed_in: true, user: { id: 'u9', name: 'Amina Wanjiru', phone: '+254722000111' } })
    expect(cookie(res, 'broka_at')).toContain('broka_at=A')
    // The proof of the phone has done its job.
    expect(cookie(res, 'broka_pv')).toMatch(/Max-Age=0/i)
  })

  it('never turns a missing tick into a yes', async () => {
    const { to } = stubFetch({ [api('/auth/otp/sign-in/register')]: json({ detail: 'Accept the Terms to continue.' }, 400) })
    const res = await createAccount(
      request('/api/stores/session/account', {
        body: { name: 'Amina Wanjiru', age_confirmed: true, terms_accepted: 'yes' },
        headers: FROM_PAGE,
        cookies: { broka_pv: 'PHONE-PROOF-0123456789' },
      }),
    )
    expect((to(api('/auth/otp/sign-in/register'))[0]!.body as { legal_acceptance: unknown }).legal_acceptance).toMatchObject({
      age_confirmed: true,
      terms_accepted: false,
      privacy_acknowledged: false,
    })
    expect(res.status).toBe(400)
    expect(setCookies(res)).toEqual([])
  })
})

describe('sending an order request', () => {
  const KEY = { 'x-idempotency-key': 'a1b2c3d4e5f6a7b8' }
  const post = (body: unknown, over: { headers?: Record<string, string>; cookies?: Record<string, string>; store?: string } = {}) =>
    submitOrder(
      request('/api/stores/s1/orders', {
        body,
        headers: { ...FROM_PAGE, ...KEY, ...over.headers },
        cookies: over.cookies ?? { broka_at: 'tok' },
      }),
      ctx({ id: over.store ?? 's1' }),
    )

  it('passes on what the buyer decided and nothing they could use to set a price or a status', async () => {
    const { to } = stubFetch({ [api('/orders')]: json({ id: 'o1' }, 201) })
    const res = await post({
      items: [{ listing_id: 'l1', quantity: 2, price: 1, unit_price_minor: 1, line_total_minor: 1 }],
      total_minor: 1,
      status: 'confirmed',
      fulfilment: 'collection',
      surface: 'app',
      note: 'After 5pm',
      via: 'whatsapp',
      campaign: 'abcdefgh12',
    })
    expect(res.status).toBe(201)
    const call = to(api('/orders'), 'POST')[0]!
    expect(call.body).toEqual({
      store_id: 's1',
      items: [{ listing_id: 'l1', quantity: 2 }],
      fulfilment: 'collection',
      note: 'After 5pm',
      surface: 'web',
      via: 'whatsapp',
      campaign: 'abcdefgh12',
    })
    expect(call.headers['x-idempotency-key']).toBe('a1b2c3d4e5f6a7b8')
    expect(call.headers.authorization).toBe('Bearer tok')
  })

  it('delivers unless the buyer asked to collect', async () => {
    const { to } = stubFetch({ [api('/orders')]: json({ id: 'o1' }, 201) })
    await post({ items: [{ listing_id: 'l1', quantity: 1 }], fulfilment: 'teleport', delivery_address: 'Kilimani' })
    expect(to(api('/orders'))[0]!.body).toMatchObject({ fulfilment: 'delivery', delivery_address: 'Kilimani' })
  })

  it('drops a campaign token of the wrong shape instead of passing it on', async () => {
    const { to } = stubFetch({ [api('/orders')]: json({ id: 'o1' }, 201) })
    await post({ items: [{ listing_id: 'l1', quantity: 1 }], fulfilment: 'collection', campaign: '../../etc' })
    expect(to(api('/orders'))[0]!.body).not.toHaveProperty('campaign')
  })

  it('needs a request key: without one a retry could not be recognised', async () => {
    const { fn } = stubFetch({})
    const res = await submitOrder(
      request('/api/stores/s1/orders', { body: { items: [] }, headers: FROM_PAGE, cookies: { broka_at: 'tok' } }),
      ctx({ id: 's1' }),
    )
    expect(res.status).toBe(400)
    expect(fn).not.toHaveBeenCalled()
  })

  it('refuses a store id that is not one, before building any address from it', async () => {
    const { fn } = stubFetch({})
    const res = await post({ items: [] }, { store: '../admin' })
    expect(res.status).toBe(400)
    expect(fn).not.toHaveBeenCalled()
  })

  it('answers "sign in" without calling the API when nobody is signed in', async () => {
    const { fn } = stubFetch({})
    const res = await post({ items: [{ listing_id: 'l1', quantity: 1 }], fulfilment: 'collection' }, { cookies: {} })
    expect(res.status).toBe(401)
    expect(await res.json()).toMatchObject({ error: { code: 'SIGNED_OUT' } })
    expect(fn).not.toHaveBeenCalled()
  })

  it("passes the API's reason on, with the product it is about, in the one error shape", async () => {
    stubFetch({
      [api('/orders')]: json({ detail: { code: 'ORDER_ITEM_OUT_OF_STOCK', message: 'Only 1 left.', listing_id: 'l1' } }, 409),
    })
    const res = await post({ items: [{ listing_id: 'l1', quantity: 2 }], fulfilment: 'collection' })
    expect(res.status).toBe(409)
    expect(await res.json()).toEqual({ error: { code: 'ORDER_ITEM_OUT_OF_STOCK', message: 'Only 1 left.', listing_id: 'l1' } })
  })
})

describe("a buyer's actions on an order", () => {
  const act = (action: string, body: unknown = {}, order = 'o1') =>
    orderAction(
      request(`/api/stores/orders/${order}/${action}`, { body, headers: FROM_PAGE, cookies: { broka_at: 'tok' } }),
      ctx({ orderId: order, action }),
    )

  it.each(['accept', 'propose', 'decline', 'preparing', 'ready', 'dispatch', 'delivered', 'stock', '..', 'constructor', 'toString', '__proto__'])(
    "has no route for the store's action %s",
    async (action: string) => {
      const { fn } = stubFetch({})
      const res = await act(action)
      expect(res.status).toBe(404)
      expect(fn).not.toHaveBeenCalled()
    },
  )

  it('refuses an order id that is not one', async () => {
    const { fn } = stubFetch({})
    expect((await act('cancel', {}, '../../admin')).status).toBe(404)
    expect(fn).not.toHaveBeenCalled()
  })

  it('confirms by the revision the buyer saw, and passes nothing else', async () => {
    const { to } = stubFetch({ [api('/orders/o1/confirm')]: json({ id: 'o1', status: 'confirmed' }) })
    await act('confirm', { revision: 3, status: 'completed', total_minor: 1 })
    expect(to(api('/orders/o1/confirm'))[0]!.body).toEqual({ revision: 3 })
  })

  it('a revision that is not a whole number is sent as 0, which the API refuses', async () => {
    const { to } = stubFetch({ [api('/orders/o1/confirm')]: json({ detail: { code: 'INVALID', message: 'x' } }, 422) })
    await act('confirm', { revision: '3' })
    expect(to(api('/orders/o1/confirm'))[0]!.body).toEqual({ revision: 0 })
  })

  it('cuts a cancel reason to the length the API takes', async () => {
    const { to } = stubFetch({ [api('/orders/o1/cancel')]: json({ id: 'o1' }) })
    await act('cancel', { reason: 'x'.repeat(500) })
    expect((to(api('/orders/o1/cancel'))[0]!.body as { reason: string }).reason).toHaveLength(300)
  })

  it('records a payment arrangement only when it is one of the two on offer', async () => {
    const { to } = stubFetch({ [api('/orders/o1/payment-arrangement')]: json({ id: 'o1' }) })
    await act('payment-arrangement', { arrangement: 'independent_escrow', provider_id: 'p1' })
    await act('payment-arrangement', { arrangement: 'direct_to_seller', provider_id: 'p1' })
    await act('payment-arrangement', { arrangement: 'bitcoin', provider_id: 'p1' })
    const bodies = to(api('/orders/o1/payment-arrangement')).map((c) => c.body)
    expect(bodies[0]).toEqual({ arrangement: 'independent_escrow', provider_id: 'p1' })
    // A provider belongs to the escrow choice only.
    expect(bodies[1]).toEqual({ arrangement: 'direct_to_seller' })
    // Never guessed into "pay the store directly".
    expect(bodies[2]).toEqual({})
  })

  it('passes a payment report as the buyer wrote it, nothing more', async () => {
    const { to } = stubFetch({ [api('/orders/o1/payment-reports')]: json({ id: 'o1' }) })
    await act('payment-reports', { kind: 'buyer_reported_payment_sent', reference: 'TX123', note: '', verified: true })
    expect(to(api('/orders/o1/payment-reports'))[0]!.body).toEqual({ kind: 'buyer_reported_payment_sent', reference: 'TX123' })
  })

  it('passes the API\'s refusal on with its reason, and a lapsed session as signed out', async () => {
    stubFetch({
      [api('/orders/o1/cancel')]: json({ detail: { code: 'ORDER_STATE_CONFLICT', message: 'The store has started preparing it.' } }, 409),
    })
    const refused = await act('cancel')
    expect(refused.status).toBe(409)
    expect(await refused.json()).toEqual({ error: { code: 'ORDER_STATE_CONFLICT', message: 'The store has started preparing it.' } })
    const out = await orderAction(request('/api/stores/orders/o1/cancel', { body: {}, headers: FROM_PAGE }), ctx({ orderId: 'o1', action: 'cancel' }))
    expect(out.status).toBe(401)
  })
})

describe('reading orders', () => {
  it("lists the buyer's orders by the scope asked for, 20 at a time", async () => {
    const { calls } = stubFetch({ [api('/orders?')]: json({ items: [], total: 0 }) })
    await listOrders(request('/api/stores/orders?scope=closed&offset=40', { cookies: { broka_at: 'tok' } }))
    await listOrders(request('/api/stores/orders?scope=everything&offset=-5', { cookies: { broka_at: 'tok' } }))
    expect(calls.map((c) => c.url)).toEqual([
      api('/orders?scope=closed&limit=20&offset=40'),
      api('/orders?scope=all&limit=20&offset=0'),
    ])
  })

  it('opens one order, and marks its updates read', async () => {
    const { to } = stubFetch({
      [api('/orders/o1')]: json({ id: 'o1', status: 'confirmed' }),
      [api('/orders/notifications/read')]: json({ marked: 1 }),
    })
    const res = await readOrder(request('/api/stores/orders/o1', { cookies: { broka_at: 'tok' } }), ctx({ orderId: 'o1' }))
    expect(await res.json()).toEqual({ id: 'o1', status: 'confirmed' })
    expect(to(api('/orders/notifications/read'))[0]!.body).toEqual({ order_id: 'o1' })
  })

  it("does not mark anything read for an order that isn't the buyer's", async () => {
    const { to } = stubFetch({
      [api('/orders/o2')]: json({ detail: { code: 'ORDER_NOT_FOUND', message: 'Order not found' } }, 404),
    })
    const res = await readOrder(request('/api/stores/orders/o2', { cookies: { broka_at: 'tok' } }), ctx({ orderId: 'o2' }))
    expect(res.status).toBe(404)
    expect(to(api('/orders/notifications/read'))).toHaveLength(0)
  })
})

describe('asking a store a question', () => {
  const messages = [
    { id: 'm1', role: 'buyer', content: 'Is it in stock?', msg_type: 'text', created_at: '2026-11-17T08:00:00', via_ai: false },
    { id: 'm2', role: 'seller', content: 'Yes, two left.', msg_type: 'text', created_at: '2026-11-17T08:05:00', via_ai: false },
    { id: 'm3', role: 'seller', content: 'Zeno private note', msg_type: 'text', created_at: '2026-11-17T08:06:00', via_ai: true },
    { id: 'm4', role: 'assistant', content: 'Zeno reply', msg_type: 'text', created_at: '2026-11-17T08:07:00', via_ai: false },
    { id: 'm5', role: 'buyer', content: '', msg_type: 'deleted', created_at: '2026-11-17T08:08:00', via_ai: false },
    { id: 'm6', role: 'seller', content: '', msg_type: 'call', created_at: '2026-11-17T08:09:00', via_ai: false },
    { id: 'm7', role: 'seller', content: 'photo.jpg', msg_type: 'image', media_url: 'https://cdn/x.jpg', created_at: '2026-11-17T08:10:00', via_ai: false },
  ]

  it("reads the store's thread, or the product's, from the conversations the app already has", async () => {
    const { calls } = stubFetch({ [api('/negotiate/')]: json(messages) })
    await readThread(request('/api/stores/s1/enquiries', { cookies: { broka_at: 't' } }), ctx({ id: 's1' }))
    await readThread(request('/api/stores/s1/enquiries?listing=l1', { cookies: { broka_at: 't' } }), ctx({ id: 's1' }))
    expect(calls.map((c) => c.url)).toEqual([api('/negotiate/store/s1/history'), api('/negotiate/l1/history')])
  })

  it('shows the buyer the human conversation only: no Zeno, no deleted or call rows, no media addresses', async () => {
    stubFetch({ [api('/negotiate/')]: json(messages) })
    const res = await readThread(request('/api/stores/s1/enquiries', { cookies: { broka_at: 't' } }), ctx({ id: 's1' }))
    const { messages: shown } = (await res.json()) as { messages: Array<Record<string, unknown>> }
    expect(shown.map((m) => m.id)).toEqual(['m1', 'm2', 'm7'])
    expect(shown[0]).toEqual({ id: 'm1', role: 'buyer', content: 'Is it in stock?', kind: 'text', created_at: '2026-11-17T08:00:00' })
    // A photo is a mention, not a link to somewhere else.
    expect(shown[2]).toMatchObject({ kind: 'image', content: '' })
    expect(JSON.stringify(shown)).not.toContain('cdn')
  })

  it('refuses a listing id that is not one', async () => {
    const { fn } = stubFetch({})
    const res = await readThread(request('/api/stores/s1/enquiries?listing=../x', { cookies: { broka_at: 't' } }), ctx({ id: 's1' }))
    expect(res.status).toBe(404)
    expect(fn).not.toHaveBeenCalled()
  })

  it("keeps the id the buyer's browser sent its own message with - never one on the store's side", async () => {
    stubFetch({
      [api('/negotiate/')]: json([
        { id: 'm1', role: 'buyer', content: 'Hi', msg_type: 'text', created_at: '2026-11-17T08:00:00', via_ai: false, client_msg_id: 'abcdefgh1234' },
        { id: 'm2', role: 'seller', content: 'Hello', msg_type: 'text', created_at: '2026-11-17T08:01:00', via_ai: false, client_msg_id: 'sellerside12' },
        { id: 'm3', role: 'buyer', content: 'Hm', msg_type: 'text', created_at: '2026-11-17T08:02:00', via_ai: false, client_msg_id: 'not an id!' },
      ]),
    })
    const res = await readThread(request('/api/stores/s1/enquiries', { cookies: { broka_at: 't' } }), ctx({ id: 's1' }))
    const { messages: shown } = (await res.json()) as { messages: Array<Record<string, unknown>> }
    expect(shown.map((m) => m.client_msg_id)).toEqual(['abcdefgh1234', undefined, undefined])
  })

  it("sends the question with the id that makes a retry the same message, and a bad id is dropped", async () => {
    const { to } = stubFetch({ [api('/stores/s1/enquiries')]: json({ id: 'm9' }, 201) })
    const ask = (body: unknown) =>
      askStore(request('/api/stores/s1/enquiries', { body, headers: FROM_PAGE, cookies: { broka_at: 't' } }), ctx({ id: 's1' }))
    await ask({ content: 'Is it in stock?', listing_id: 'l1', client_msg_id: 'abcdefgh1234', sender_id: 'someone-else' })
    await ask({ content: 'y'.repeat(3000), client_msg_id: 'x' })
    const [first, second] = to(api('/stores/s1/enquiries')).map((c) => c.body as Record<string, unknown>)
    expect(first).toEqual({ content: 'Is it in stock?', listing_id: 'l1', client_msg_id: 'abcdefgh1234' })
    expect(second!.content).toHaveLength(2000)
    expect(second).not.toHaveProperty('client_msg_id')
  })
})

describe("the buyer's conversations with stores", () => {
  const inbox = [
    {
      thread_type: 'store',
      store_id: 's1',
      listing_id: null,
      my_role: 'buyer',
      last_message: 'Yes, two left.',
      last_role: 'seller',
      last_msg_type: 'text',
      last_message_at: '2026-11-17T08:05:00Z',
      unread: 2,
    },
    // The user's own store's side of a thread: answered from the app.
    { listing_id: 'l9', my_role: 'seller', last_message: 'Hi', last_role: 'buyer', last_msg_type: 'text' },
  ]

  it("reads the app's inbox as the signed-in buyer, and returns the conversations a store page can open", async () => {
    const { to } = stubFetch({
      [api('/negotiate/inbox/u1')]: json(inbox),
      [api('/stores/s1')]: json({ id: 's1', name: 'Clanix', slug: 'clanix', is_active: true, orders_enabled: true, logo: null, logo_url: null }),
    })
    const res = await listConversations(request('/api/stores/conversations?user=u1', { cookies: { broka_at: 'tok' } }))
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({
      conversations: [
        {
          key: 'store:s1',
          store: { id: 's1', slug: 'clanix', name: 'Clanix', logo: null },
          product: null,
          last: { text: 'Yes, two left.', from: 'seller', at: '2026-11-17T08:05:00Z' },
          href: '/store/clanix/messages',
        },
      ],
      partial: false,
    })
    expect(to(api('/negotiate/inbox/u1'))[0]!.headers.authorization).toBe('Bearer tok')
    // Reading the list marks nothing read: no seller is told the buyer saw anything.
    expect(to(api('/negotiate/store/'))).toHaveLength(0)
    expect(res.headers.get('cache-control')).toBe('no-store')
  })

  it('needs an id that is one, before building an address from it', async () => {
    const { fn } = stubFetch({})
    for (const path of ['/api/stores/conversations', '/api/stores/conversations?user=../admin']) {
      const res = await listConversations(request(path, { cookies: { broka_at: 'tok' } }))
      expect(res.status).toBe(400)
    }
    expect(fn).not.toHaveBeenCalled()
  })

  it("passes the API's refusal of another account's inbox on, and a missing session as signed out", async () => {
    stubFetch({ [api('/negotiate/inbox/u2')]: json({ detail: "Cannot access another user's inbox." }, 403) })
    const refused = await listConversations(request('/api/stores/conversations?user=u2', { cookies: { broka_at: 'tok' } }))
    expect(refused.status).toBe(403)
    expect(await refused.json()).toEqual({ error: { code: 'HTTP_403', message: "Cannot access another user's inbox." } })
    const out = await listConversations(request('/api/stores/conversations?user=u1'))
    expect(out.status).toBe(401)
  })
})

describe('counting a product put in the cart', () => {
  it('passes on only the fields the count uses, as a web visit, with no sign-in', async () => {
    const { to } = stubFetch({ [api('/stores/s1/cart-events')]: new Response(null, { status: 202 }) })
    const res = await cartEvent(
      new Request('https://broka.co.ke/api/stores/s1/cart-events', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ listing_id: 'l1', via: 'tiktok', visitor: 'abcdefgh1234', surface: 'app', quantity: 99, buyer_id: 'u1' }),
      }),
      ctx({ id: 's1' }),
    )
    expect(res.status).toBeLessThan(300)
    expect(to(api('/stores/s1/cart-events'))[0]!.body).toEqual({
      surface: 'web', listing_id: 'l1', via: 'tiktok', visitor: 'abcdefgh1234',
    })
    expect(to(api('/stores/s1/cart-events'))[0]!.headers.authorization).toBeUndefined()
  })
})
