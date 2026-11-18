import { render, screen, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { resetSession } from '@/lib/session-client'
import type { Listing, Store } from '@/lib/types'
import { json, SIGNED_IN, storeFixture, stubFetch } from '@/test/fixtures'

class Navigated extends Error {
  constructor(readonly kind: string, readonly to?: string) {
    super(`${kind} ${to ?? ''}`)
  }
}
vi.mock('next/navigation', () => ({
  notFound: () => {
    throw new Navigated('notFound')
  },
  redirect: (to: string) => {
    throw new Navigated('redirect', to)
  },
  permanentRedirect: (to: string) => {
    throw new Navigated('permanentRedirect', to)
  },
}))

const api = vi.hoisted(() => ({ getStore: vi.fn(), getListing: vi.fn() }))
vi.mock('@/lib/api', () => api)

const { default: MessagesPage } = await import('./page')

const store = (over: Partial<Store> = {}) => storeFixture({ orders_enabled: true, ...over })

const props = (name = 'clanix', query: Record<string, string> = {}) => ({
  params: Promise.resolve({ name }),
  searchParams: Promise.resolve(query),
})

async function whereTo(p: ReturnType<typeof props>): Promise<Navigated | null> {
  try {
    await MessagesPage(p)
    return null
  } catch (e) {
    if (e instanceof Navigated) return e
    throw e
  }
}

describe('messaging a store on its website', () => {
  beforeEach(() => {
    resetSession()
    api.getStore.mockReset()
    api.getListing.mockReset()
  })
  afterEach(() => vi.unstubAllGlobals())

  it('exists only with store orders on: otherwise the store page offers the app, as before', async () => {
    api.getStore.mockResolvedValue(store({ orders_enabled: false }))
    expect(await whereTo(props())).toMatchObject({ kind: 'redirect', to: '/store/clanix' })
    api.getStore.mockResolvedValue(store({ orders_enabled: undefined }))
    expect(await whereTo(props())).toMatchObject({ kind: 'redirect', to: '/store/clanix' })
  })

  it('a paused store sends visitors to its page, and an unknown one is not found', async () => {
    api.getStore.mockResolvedValue(store({ is_active: false }))
    expect(await whereTo(props())).toMatchObject({ kind: 'redirect', to: '/store/clanix' })
    api.getStore.mockResolvedValue(null)
    expect((await whereTo(props('nope')))?.kind).toBe('notFound')
  })

  it("tidies the address to the store's own link, keeping the product", async () => {
    api.getStore.mockResolvedValue(store())
    expect(await whereTo(props('Clanix', { product: 'l1' }))).toMatchObject({
      kind: 'permanentRedirect',
      to: '/store/clanix/messages?product=l1',
    })
    // Anything that is not an id is dropped.
    expect(await whereTo(props('Clanix', { product: '<script>' }))).toMatchObject({
      kind: 'permanentRedirect',
      to: '/store/clanix/messages',
    })
  })

  it('marks Messages as the section the buyer is in - not About, which the page used to mark', async () => {
    api.getStore.mockResolvedValue(store())
    stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/s1/enquiries': json({ messages: [] }),
      '/api/stores/conversations': json({ conversations: [], partial: false }),
    })
    render(await MessagesPage(props()))
    const sections = screen.getByRole('navigation', { name: 'Store sections' })
    expect(within(sections).getByRole('link', { name: 'Messages' }).getAttribute('aria-current')).toBe('page')
    expect(within(sections).getByRole('link', { name: 'About' }).hasAttribute('aria-current')).toBe(false)
    await screen.findByTestId('enquiry-thread')
  })

  it('keeps the product in view while asking about it, with the way back to it and on to the shop', async () => {
    api.getStore.mockResolvedValue(store())
    api.getListing.mockResolvedValue({
      id: 'l1',
      name: 'Samsung A15',
      store_id: 's1',
      price: 15000,
      category: 'Electronics',
      photos: [],
      cover: null,
    } as unknown as Listing)
    stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/s1/enquiries': json({ messages: [] }),
      '/api/stores/conversations': json({ conversations: [], partial: false }),
    })
    render(await MessagesPage(props('clanix', { product: 'l1' })))
    const product = await screen.findByTestId('chat-product')
    expect(product.getAttribute('href')).toBe('/store/clanix/p/l1')
    expect(product.textContent).toContain('Samsung A15')
    expect(product.textContent).toContain('KES 15,000')
    expect(screen.getByRole('link', { name: 'Back to Samsung A15' }).getAttribute('href')).toBe('/store/clanix/p/l1')
    expect(screen.getByRole('link', { name: 'Continue shopping at Clanix' }).getAttribute('href')).toBe('/store/clanix/shop')
    // The path back through the product to the store.
    const crumbs = screen.getByRole('navigation', { name: 'Breadcrumb' })
    expect(within(crumbs).getAllByRole('link').map((a) => a.getAttribute('href'))).toEqual(['/store/clanix', '/store/clanix/p/l1'])
  })

  it("lists the buyer's conversations with this store beside the open one, and the way to all of them", async () => {
    // A wide screen: on a phone the list is not there to read (MessagingWorkspace).
    vi.stubGlobal('matchMedia', (query: string) => ({
      matches: query.includes('min-width: 861px'),
      media: query,
      addEventListener: () => {},
      removeEventListener: () => {},
    }))
    api.getStore.mockResolvedValue(store())
    const conversation = (key: string, over: Record<string, unknown> = {}) => ({
      key,
      store: { id: 's1', slug: 'clanix', name: 'Clanix', logo: null },
      product: null,
      last: { text: 'Yes, two left.', from: 'seller', at: '2026-11-17T08:05:00Z' },
      href: '/store/clanix/messages',
      ...over,
    })
    const stub = stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/s1/enquiries': json({ messages: [] }),
      '/api/stores/conversations': json({
        conversations: [
          conversation('product:l2', { product: { id: 'l2', name: 'Phone case', image: null }, href: '/store/clanix/messages?product=l2' }),
          conversation('store:s1'),
          conversation('store:s2', { store: { id: 's2', slug: 'java', name: 'Java', logo: null }, href: '/store/java/messages' }),
        ],
        partial: false,
      }),
    })
    render(await MessagesPage(props()))
    const list = await screen.findByRole('list', { name: 'Conversations with Clanix' })
    const rows = within(list).getAllByTestId('conversation')
    expect(rows.map((r) => [r.getAttribute('href'), r.getAttribute('aria-current')])).toEqual([
      ['/store/clanix/messages?product=l2', null],
      ['/store/clanix/messages', 'page'],
    ])
    const all = screen.getByRole('link', { name: /All your conversations/ })
    expect(all.getAttribute('href')).toBe('/store/account/messages')
    expect(all.textContent).toContain('1 with other stores')
    expect(stub.to('/api/stores/conversations')[0]!.url).toBe('/api/stores/conversations?user=u1')
  })

  it("asks about the store's own product in that product's thread", async () => {
    api.getStore.mockResolvedValue(store())
    api.getListing.mockResolvedValue({ id: 'l1', name: 'Samsung A15', store_id: 's1' } as Listing)
    const stub = stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/s1/enquiries': json({ messages: [] }),
      '/api/stores/conversations': json({ conversations: [], partial: false }),
    })
    render(await MessagesPage(props('clanix', { product: 'l1' })))
    expect(await screen.findByRole('heading', { name: 'Ask Clanix about Samsung A15' })).toBeTruthy()
    expect(stub.to('/api/stores/s1/enquiries')[0]!.url).toBe('/api/stores/s1/enquiries?listing=l1')
  })

  it('on a phone the page is the conversation alone: no list of conversations is read for it', async () => {
    api.getStore.mockResolvedValue(store())
    const stub = stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/s1/enquiries': json({ messages: [] }),
      '/api/stores/conversations': json({ conversations: [], partial: false }),
    })
    render(await MessagesPage(props()))
    await screen.findByText(/No messages yet/)
    expect(screen.queryByRole('list', { name: 'Conversations with Clanix' })).toBeNull()
    expect(stub.to('/api/stores/conversations')).toHaveLength(0)
    expect(screen.getByRole('link', { name: 'All conversations' }).getAttribute('href')).toBe('/store/account/messages')
  })

  it("a product from another store is not this store's to answer: the store's own thread opens", async () => {
    api.getStore.mockResolvedValue(store())
    api.getListing.mockResolvedValue({ id: 'l9', name: 'Somebody else’s phone', store_id: 's2' } as Listing)
    const stub = stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/s1/enquiries': json({ messages: [] }),
      '/api/stores/conversations': json({ conversations: [], partial: false }),
    })
    render(await MessagesPage(props('clanix', { product: 'l9' })))
    expect(await screen.findByRole('heading', { name: 'Message Clanix' })).toBeTruthy()
    expect(stub.to('/api/stores/s1/enquiries')[0]!.url).toBe('/api/stores/s1/enquiries')
  })
})
