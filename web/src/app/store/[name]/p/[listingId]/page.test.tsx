import { beforeEach, describe, expect, it, vi } from 'vitest'

import type { Listing, Store } from '@/lib/types'

// Next's navigation helpers throw to stop rendering; here they record where
// the page sent the visitor instead.
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

const api = vi.hoisted(() => ({ getStore: vi.fn(), getListing: vi.fn(), getStoreListings: vi.fn() }))
vi.mock('@/lib/api', () => api)

const { default: ProductPage, generateMetadata } = await import('./page')

const store = (over: Partial<Store> = {}) =>
  ({ id: 's1', name: 'Clanix', slug: 'clanix', is_active: true, ...over }) as Store
const listing = (over: Partial<Listing> = {}) =>
  ({ id: 'l1', name: 'Phone', price: 1000, status: 'active', store_id: 's1', photos: [], ...over }) as Listing

const props = (name = 'clanix', query: Record<string, string> = {}) => ({
  params: Promise.resolve({ name, listingId: 'l1' }),
  searchParams: Promise.resolve(query),
})

async function whereTo(p: ReturnType<typeof props>): Promise<Navigated | null> {
  try {
    await ProductPage(p)
    return null
  } catch (e) {
    if (e instanceof Navigated) return e
    throw e
  }
}

describe('product page', () => {
  beforeEach(() => {
    api.getStore.mockReset()
    api.getListing.mockReset()
    api.getStoreListings.mockReset().mockResolvedValue([])
  })

  it("a paused store's product link goes to the store page, keeping the tag", async () => {
    api.getStore.mockResolvedValue(store({ is_active: false }))
    api.getListing.mockResolvedValue(listing())
    const nav = await whereTo(props('clanix', { via: 'whatsapp' }))
    expect(nav?.kind).toBe('redirect')
    expect(nav?.to).toBe('/store/clanix?via=whatsapp')
    const meta = await generateMetadata(props())
    expect(meta.robots).toEqual({ index: false })
  })

  it("a product that isn't this store's is not found", async () => {
    api.getStore.mockResolvedValue(store())
    api.getListing.mockResolvedValue(listing({ store_id: 'other' }))
    expect((await whereTo(props()))?.kind).toBe('notFound')
  })

  it('an open store renders the product', async () => {
    api.getStore.mockResolvedValue(store())
    api.getListing.mockResolvedValue(listing())
    expect(await whereTo(props())).toBeNull()
    // "More from the store" asks for a few of its products.
    expect(api.getStoreListings).toHaveBeenCalledWith('s1', { limit: 9 })
  })

  it('renders even when "More from the store" cannot load', async () => {
    api.getStore.mockResolvedValue(store())
    api.getListing.mockResolvedValue(listing())
    api.getStoreListings.mockRejectedValue(new Error('API asleep'))
    expect(await whereTo(props())).toBeNull()
  })
})
