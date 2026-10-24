import { render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type { Store, StoreReviews } from '@/lib/types'

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
  permanentRedirect: (to: string) => {
    throw new Navigated('permanentRedirect', to)
  },
}))

const api = vi.hoisted(() => ({ getStore: vi.fn(), getStoreReviews: vi.fn() }))
vi.mock('@/lib/api', () => api)

const { default: StoreDetailsPage } = await import('./page')

const store: Store = {
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
  listing_count: 3,
  rating: 6.5,
  review_count: 2,
  created_at: '2026-09-02T08:00:00',
}

const reviews: StoreReviews = {
  summary: { avg: 4.5, count: 2, distribution: { '5': 1, '4': 1, '3': 0, '2': 0, '1': 0 } },
  reviews: [
    {
      id: 'r1',
      rating: 5,
      comment: 'Phone exactly as described.',
      created_at: '2026-09-20T10:00:00',
      reviewer_name: 'Amina W.',
    },
  ],
}

const props = (name = 'clanix') => ({
  params: Promise.resolve({ name }),
  searchParams: Promise.resolve({}),
})

describe('store details page', () => {
  beforeEach(() => {
    api.getStore.mockReset().mockResolvedValue(store)
    api.getStoreReviews.mockReset().mockResolvedValue(reviews)
    // VisitBeacon reports the visit from an effect.
    vi.stubGlobal('fetch', vi.fn(async () => new Response(null, { status: 204 })))
  })

  afterEach(() => vi.unstubAllGlobals())

  it("asks for this shop's reviews and shows them", async () => {
    render(await StoreDetailsPage(props()))
    expect(api.getStoreReviews).toHaveBeenCalledWith('s1')
    expect(screen.getByRole('heading', { name: 'Store score' })).toBeTruthy()
    const buyer = screen.getByRole('heading', { name: 'Buyer reviews' }).parentElement!
    expect(buyer.textContent).toContain('4.5/5')
    expect(buyer.textContent).toContain('2 reviews')
    expect(screen.getByText('Amina W.')).toBeTruthy()
    expect(screen.getByText('Phone exactly as described.')).toBeTruthy()
  })

  it('keeps the rest of the page when reviews cannot load', async () => {
    api.getStoreReviews.mockRejectedValue(new Error('API asleep'))
    render(await StoreDetailsPage(props()))
    expect(screen.getByText("Reviews aren't available right now.")).toBeTruthy()
    expect(screen.getByText('Genuine phones and accessories.')).toBeTruthy()
    expect(screen.getByText('Buying safely')).toBeTruthy()
  })

  it("tidies /store/Clanix/about to the store's own link", async () => {
    await expect(StoreDetailsPage(props('Clanix'))).rejects.toMatchObject({
      kind: 'permanentRedirect',
      to: '/store/clanix/about',
    })
  })
})
