import { render, screen } from '@testing-library/react'
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

  it("asks about the store's own product in that product's thread", async () => {
    api.getStore.mockResolvedValue(store())
    api.getListing.mockResolvedValue({ id: 'l1', name: 'Samsung A15', store_id: 's1' } as Listing)
    const stub = stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/s1/enquiries': json({ messages: [] }),
    })
    render(await MessagesPage(props('clanix', { product: 'l1' })))
    expect(await screen.findByRole('heading', { name: 'Ask Clanix about Samsung A15' })).toBeTruthy()
    expect(stub.to('/api/stores/s1/enquiries')[0]!.url).toBe('/api/stores/s1/enquiries?listing=l1')
  })

  it("a product from another store is not this store's to answer: the store's own thread opens", async () => {
    api.getStore.mockResolvedValue(store())
    api.getListing.mockResolvedValue({ id: 'l9', name: 'Somebody else’s phone', store_id: 's2' } as Listing)
    const stub = stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/s1/enquiries': json({ messages: [] }),
    })
    render(await MessagesPage(props('clanix', { product: 'l9' })))
    expect(await screen.findByRole('heading', { name: 'Message Clanix' })).toBeTruthy()
    expect(stub.to('/api/stores/s1/enquiries')[0]!.url).toBe('/api/stores/s1/enquiries')
  })
})
