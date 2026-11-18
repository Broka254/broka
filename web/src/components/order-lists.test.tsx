import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { beforeEach, describe, expect, it } from 'vitest'

import type { OrderSummary } from '@/lib/orders'
import { resetSession } from '@/lib/session-client'
import { json, SIGNED_IN, stubFetch } from '@/test/fixtures'

import { EnquiryThread } from './EnquiryThread'
import { OrdersList } from './OrdersList'

beforeEach(() => resetSession())

const summary = (over: Partial<OrderSummary> = {}): OrderSummary => ({
  id: 'o1',
  reference: 'BK-1001',
  status: 'awaiting_buyer_confirmation',
  status_label: 'Waiting for your confirmation',
  open: true,
  needs_action: true,
  item_count: 2,
  first_item: 'Samsung A15',
  currency: 'KES',
  total_minor: 1_530_000,
  final: false,
  fulfilment: 'delivery',
  created_at: '2026-11-17T08:00:00+00:00',
  updated_at: '2026-11-17T08:05:00+00:00',
  expires_at: null,
  store: { id: 's1', name: 'Clanix', slug: 'clanix' },
  ...over,
})

describe('OrdersList', () => {
  it("lists the buyer's open orders, marks the ones waiting on them, and links each one", async () => {
    stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/orders?scope=open': json({ items: [summary()], total: 1 }),
    })
    render(<OrdersList />)
    const card = (await screen.findByText('Clanix')).closest('a')!
    expect(card.getAttribute('href')).toBe('/store/orders/o1')
    expect(card.textContent).toContain('KES 15,300')
    expect(card.textContent).toContain('Waiting for your confirmation')
    expect(card.textContent).toContain('BK-1001 · Samsung A15 and 1 more')
    expect(card.textContent).toContain('Waiting for you')
    expect(screen.getByRole('tab', { name: 'In progress' }).getAttribute('aria-selected')).toBe('true')
  })

  it('switching tabs reads that list, and never shows the last tab\'s orders under the new one', async () => {
    let releaseClosed!: () => void
    const closedGate = new Promise<void>((resolve) => {
      releaseClosed = resolve
    })
    const stub = stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/orders?scope=open': json({ items: [summary()], total: 1 }),
      '/api/stores/orders?scope=closed': async () => {
        await closedGate
        return json({ items: [], total: 0 })
      },
    })
    render(<OrdersList />)
    await screen.findByText('Clanix')
    fireEvent.click(screen.getByRole('tab', { name: 'Finished' }))
    // While the finished orders load, the open one is not shown as finished.
    expect(screen.queryByText('Clanix')).toBeNull()
    releaseClosed()
    expect(await screen.findByText(/No orders here yet\./)).toBeTruthy()
    expect(stub.calls.filter((c) => c.url.startsWith('/api/stores/orders')).map((c) => c.url)).toEqual([
      '/api/stores/orders?scope=open',
      '/api/stores/orders?scope=closed',
    ])
  })

  it('says what went wrong, and "Try again" reads the list again', async () => {
    let attempt = 0
    stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/orders?scope=open': () =>
        ++attempt === 1
          ? json({ error: { code: 'API_UNREACHABLE', message: "Couldn't reach BROKA." } }, 503)
          : json({ items: [summary()], total: 1 }),
    })
    render(<OrdersList />)
    expect((await screen.findByRole('alert')).textContent).toContain("Couldn't reach BROKA.")
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }))
    expect(await screen.findByText('Clanix')).toBeTruthy()
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it("names each order's store and badges its status, so a list from several stores reads as none of theirs", async () => {
    stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/orders?scope=open': json({
        items: [
          summary(),
          summary({
            id: 'o2',
            reference: 'BK-2002',
            status: 'preparing',
            status_label: 'Being prepared',
            needs_action: false,
            store: { id: 's2', name: 'Java', slug: 'java' },
          }),
        ],
        total: 2,
      }),
    })
    render(<OrdersList />)
    const java = (await screen.findByText('Java')).closest('a')!
    expect(java.getAttribute('href')).toBe('/store/orders/o2')
    expect(java.textContent).toContain('Being prepared')
    expect(java.textContent).not.toContain('Waiting for you')
    const clanix = screen.getByText('Clanix').closest('a')!
    // The badge's colour follows what the status means for the buyer; the words are the API's.
    expect(within(clanix).getByText('Waiting for your confirmation').getAttribute('data-tone')).toBe('action')
    expect(within(java).getByText('Being prepared').getAttribute('data-tone')).toBe('progress')
  })

  it('an empty list leads back to shopping', async () => {
    stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/orders?scope=open': json({ items: [], total: 0 }),
    })
    render(<OrdersList />)
    expect(await screen.findByRole('heading', { name: 'Nothing in progress.' })).toBeTruthy()
    expect(screen.getByRole('link', { name: 'Get the app' })).toBeTruthy()
  })

  it('asks a signed-out visitor to sign in, and reads no orders', async () => {
    const stub = stubFetch({ '/api/stores/session': json({ signed_in: false }) })
    render(<OrdersList />)
    expect(await screen.findByRole('heading', { name: 'Sign in to see your orders' })).toBeTruthy()
    expect(stub.to('/api/stores/orders')).toHaveLength(0)
  })

  it('signing out ends the session on the server and shows the sign-in step', async () => {
    const stub = stubFetch({
      '/api/stores/session': (c) => (c.method === 'DELETE' ? json({ signed_in: false }) : json(SIGNED_IN)),
      '/api/stores/orders?scope=open': json({ items: [], total: 0 }),
    })
    render(<OrdersList />)
    fireEvent.click(await screen.findByRole('button', { name: 'Sign out' }))
    expect(await screen.findByTestId('sign-in')).toBeTruthy()
    const out = stub.to('/api/stores/session', 'DELETE')
    expect(out).toHaveLength(1)
    expect(out[0]!.headers['x-broka-web']).toBe('1')
  })
})

describe('EnquiryThread', () => {
  const thread = [
    { id: 'm1', role: 'buyer', content: 'Is it in stock?', kind: 'text', created_at: '2026-11-17T08:00:00+00:00' },
    { id: 'm2', role: 'seller', content: 'Yes, two left.', kind: 'text', created_at: '2026-11-17T08:05:00+00:00' },
    { id: 'm3', role: 'seller', content: '', kind: 'image', created_at: '2026-11-17T08:06:00+00:00' },
  ]

  it("shows the conversation with the store, and the store's photo as a mention", async () => {
    stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/s1/enquiries': json({ messages: thread }),
    })
    render(<EnquiryThread storeId="s1" storeName="Clanix" />)
    expect(await screen.findByText('Is it in stock?')).toBeTruthy()
    expect(screen.getByText('Yes, two left.')).toBeTruthy()
    expect(screen.getByText('📷 A photo - open the BROKA app to see it.')).toBeTruthy()
    expect(screen.getByRole('heading', { name: 'Message Clanix' })).toBeTruthy()
    expect(document.body.textContent).toContain('never pay to a number or link sent in a chat')
  })

  it('asks about one product in that product\'s own thread', async () => {
    const stub = stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/s1/enquiries': (c) => (c.method === 'GET' ? json({ messages: [] }) : json({ id: 'm9' }, 201)),
    })
    render(<EnquiryThread storeId="s1" storeName="Clanix" listingId="l1" productName="Samsung A15" />)
    expect(await screen.findByRole('heading', { name: 'Ask Clanix about Samsung A15' })).toBeTruthy()
    fireEvent.change(screen.getByLabelText('Your message'), { target: { value: 'Do you have it in blue?' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send' }))
    await waitFor(() => expect(stub.to('/api/stores/s1/enquiries', 'POST')).toHaveLength(1))
    expect(stub.to('/api/stores/s1/enquiries', 'GET')[0]!.url).toBe('/api/stores/s1/enquiries?listing=l1')
    expect(stub.to('/api/stores/s1/enquiries', 'POST')[0]!.body).toMatchObject({ content: 'Do you have it in blue?', listing_id: 'l1' })
  })

  it('a message that failed to send stays where it was, says why, and Retry sends it again as the same message', async () => {
    let posts = 0
    const stub = stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/s1/enquiries': (c) =>
        c.method === 'GET'
          ? json({ messages: [] })
          : ++posts === 1
            ? json({ error: { code: 'RATE_LIMITED', message: 'Too many tries. Wait a minute and try again.' } }, 429)
            : json({ id: 'm9' }, 201),
    })
    render(<EnquiryThread storeId="s1" storeName="Clanix" />)
    const box = (await screen.findByLabelText('Your message')) as HTMLTextAreaElement
    fireEvent.change(box, { target: { value: 'Do you deliver to Westlands?' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send' }))
    expect((await screen.findByRole('alert')).textContent).toContain(
      "Not sent - you've sent several messages in a short time. Wait a few minutes, then try again.",
    )
    // Still on screen as it was sent; the box is free for the next one.
    expect(screen.getByText('Do you deliver to Westlands?')).toBeTruthy()

    fireEvent.click(screen.getByRole('button', { name: 'Retry' }))
    await waitFor(() => expect(stub.to('/api/stores/s1/enquiries', 'POST')).toHaveLength(2))
    await waitFor(() => expect(screen.queryByRole('alert')).toBeNull())
    const ids = stub.to('/api/stores/s1/enquiries', 'POST').map((c) => (c.body as { client_msg_id?: string }).client_msg_id)
    expect(ids[0]).toMatch(/^[A-Za-z0-9_-]{8,64}$/)
    // The same id: the chat engine answers a repeat with the message it stored, never a second one.
    expect(ids[1]).toBe(ids[0])
    expect(screen.getAllByText('Do you deliver to Westlands?')).toHaveLength(1)
    // Sent: the thread is read again for the store's reply.
    await waitFor(() => expect(stub.to('/api/stores/s1/enquiries', 'GET').length).toBeGreaterThanOrEqual(2))
  })

  it('asks a signed-out visitor to sign in first - there is no anonymous messaging', async () => {
    const stub = stubFetch({ '/api/stores/session': json({ signed_in: false }) })
    render(<EnquiryThread storeId="s1" storeName="Clanix" />)
    expect(await screen.findByRole('heading', { name: 'Sign in to message Clanix' })).toBeTruthy()
    expect(stub.to('/api/stores/s1/enquiries')).toHaveLength(0)
  })
})
