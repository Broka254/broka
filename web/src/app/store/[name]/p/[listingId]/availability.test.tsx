import { render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type { Listing, Store } from '@/lib/types'
import { storeFixture } from '@/test/fixtures'

vi.mock('next/navigation', () => ({
  notFound: () => {
    throw new Error('notFound')
  },
  redirect: (to: string) => {
    throw new Error(`redirect ${to}`)
  },
  permanentRedirect: (to: string) => {
    throw new Error(`permanentRedirect ${to}`)
  },
  useRouter: () => ({ push: vi.fn() }),
}))

const api = vi.hoisted(() => ({
  getStore: vi.fn(),
  getListing: vi.fn(),
  getStoreListings: vi.fn(),
  getEscrowDirectory: vi.fn().mockResolvedValue({ providers: [], disclaimer: '', notices: [] }),
}))
vi.mock('@/lib/api', () => api)

const { default: ProductPage } = await import('./page')

const store = storeFixture

const listing = (over: Partial<Listing> = {}): Listing => ({
  id: 'l1',
  name: 'Samsung A15',
  category: 'Electronics',
  price: 15000,
  price_unit: null,
  quantity: null,
  status: 'active',
  listing_type: 'buy_now',
  condition: 'new',
  description: null,
  location_name: null,
  location_county: 'Nairobi',
  location_subcounty: 'Starehe',
  photos: [],
  cover: null,
  verified_photos: null,
  showcase_image_url: null,
  seller_name: 'Jane Wanjiru',
  seller_verified: true,
  seller_rating: 4.8,
  seller_completed_deals: 12,
  available: true,
  stock_tracked: false,
  available_quantity: null,
  temporarily_unavailable: false,
  store_id: 's1',
  store_slug: 'clanix',
  store_name: 'Clanix',
  ...over,
})

const props = () => ({
  params: Promise.resolve({ name: 'clanix', listingId: 'l1' }),
  searchParams: Promise.resolve({}),
})

async function show(s: Store, l: Listing) {
  api.getStore.mockResolvedValue(s)
  api.getListing.mockResolvedValue(l)
  render(await ProductPage(props()))
}

const addToCart = () => screen.queryByRole('button', { name: /Add to cart/ })

describe('product page: whether it can be ordered now', () => {
  beforeEach(() => {
    api.getStore.mockReset()
    api.getListing.mockReset()
    api.getStoreListings.mockReset().mockResolvedValue([])
    // VisitBeacon reports the visit from an effect.
    vi.stubGlobal('fetch', vi.fn(async () => new Response(null, { status: 204 })))
  })
  afterEach(() => vi.unstubAllGlobals())

  it('a product with a unit left can be ordered, whether or not the seller counts its stock', async () => {
    await show(store({ orders_enabled: true }), listing({ quantity: null, stock_tracked: false, available_quantity: 1 }))
    expect(addToCart()).toBeTruthy()
    expect(screen.queryByTestId('out-of-stock')).toBeNull()
    expect(screen.queryByTestId('paused')).toBeNull()
  })

  it('an uncounted product whose every unit is promised reads as gone, not orderable', async () => {
    // The API takes it off sale (pending) once orders and chat deals hold every unit.
    await show(
      store({ orders_enabled: true }),
      listing({ quantity: null, stock_tracked: false, available_quantity: 0, status: 'pending', sold_out: true, available: false }),
    )
    expect(screen.getByText(/isn't available any more/)).toBeTruthy()
    expect(addToCart()).toBeNull()
  })

  it('counted stock that has run out says so, offers no cart, and with store orders on a question', async () => {
    await show(
      store({ orders_enabled: true }),
      listing({ quantity: 3, stock_tracked: true, available_quantity: 0, out_of_stock: true, sold_out: true, available: false }),
    )
    const note = screen.getByTestId('out-of-stock')
    expect(note.textContent).toContain('Out of stock at Clanix right now.')
    expect(screen.getByRole('link', { name: "Ask the store when it's back." }).getAttribute('href')).toBe(
      '/store/clanix/messages?product=l1',
    )
    expect(addToCart()).toBeNull()
    // Out of stock is not "gone": the product is still the store's.
    expect(screen.queryByText(/isn't available any more/)).toBeNull()
  })

  it('a product the seller paused is shown, labelled, and not orderable', async () => {
    await show(store({ orders_enabled: true }), listing({ temporarily_unavailable: true }))
    expect(screen.getByTestId('paused').textContent).toContain("Clanix isn't taking orders for this product for now.")
    expect(addToCart()).toBeNull()
  })

  it('with store orders on, a question about the product needs no app', async () => {
    await show(store({ orders_enabled: true }), listing())
    expect(screen.getByTestId('ask-store').getAttribute('href')).toBe('/store/clanix/messages?product=l1')
    expect(screen.queryByText('Chat with the seller or make an offer in the BROKA app')).toBeNull()
  })

  it('with store orders off, the page is as it was: the app for questions, no ask link', async () => {
    await show(store(), listing())
    expect(screen.queryByTestId('ask-store')).toBeNull()
    expect(screen.getByText('Chat with the seller or make an offer in the BROKA app')).toBeTruthy()
    expect(addToCart()).toBeTruthy()
  })

  it('out of stock with store orders off says so, without a link to messages that are off', async () => {
    await show(store(), listing({ quantity: 2, stock_tracked: true, available_quantity: 0, out_of_stock: true, available: false }))
    expect(screen.getByTestId('out-of-stock').textContent).toContain('Out of stock at Clanix right now.')
    expect(screen.queryByRole('link', { name: /Ask the store/ })).toBeNull()
  })
})
