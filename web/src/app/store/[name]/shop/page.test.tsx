import { render, screen } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import type { Store } from '@/lib/types'

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

const api = vi.hoisted(() => ({ getStore: vi.fn(), getStoreCategories: vi.fn(), getStoreListings: vi.fn() }))
vi.mock('@/lib/api', () => api)

const { default: StoreShopPage, generateMetadata } = await import('./page')

// A Java-like store: real shape, no products, no description, no logo.
const store = (over: Partial<Store> = {}) =>
  ({
    id: 's1',
    name: 'Java',
    slug: 'java',
    url: 'https://broka.co.ke/store/java',
    category: 'Electronics',
    description: null,
    country: 'Kenya',
    county: 'Kiambu',
    subcounty: 'Juja',
    location_description: null,
    business_email: null,
    business_email_verified: false,
    logo: null,
    cover: null,
    photo_images: [],
    logo_url: null,
    photos: [],
    owner: { name: 'Clinton Henry', verified: false, rating: null, review_count: 0, completed_deals: 0, member_since: '2026-10-30T00:00:00' },
    is_active: true,
    listing_count: 0,
    rating: 6.5,
    review_count: 0,
    ...over,
  }) as Store

const props = (name = 'java', search: Record<string, string> = {}) => ({
  params: Promise.resolve({ name }),
  searchParams: Promise.resolve(search),
})

describe('store shop page', () => {
  beforeEach(() => {
    api.getStore.mockReset().mockResolvedValue(store())
    api.getStoreCategories.mockReset().mockResolvedValue([])
    api.getStoreListings.mockReset().mockResolvedValue([])
    vi.stubGlobal('fetch', vi.fn(async () => new Response(null, { status: 204 })))
  })

  it('shows the catalogue with a breadcrumb and no invented products', async () => {
    render(await StoreShopPage(props()))
    expect(screen.getByRole('heading', { name: 'Shop Java' })).toBeTruthy()
    expect(screen.getByRole('navigation', { name: 'Breadcrumb' })).toBeTruthy()
    expect(screen.getByText('Nothing listed yet')).toBeTruthy()
    // The catalogue read is store-scoped: the store's own id, first page.
    expect(api.getStoreListings).toHaveBeenCalledWith('s1', expect.objectContaining({ q: '', category: undefined }))
  })

  it('omits the secondary store-section navigation row', async () => {
    render(await StoreShopPage(props()))
    expect(screen.queryByRole('navigation', { name: 'Store sections' })).toBeNull()
    expect(screen.getByRole('navigation', { name: 'Breadcrumb' }).textContent).toContain('Shop')
  })

  it('carries its own canonical, not the homepage one', async () => {
    const meta = await generateMetadata(props())
    expect(meta.title).toBe('Shop Java')
    expect(meta.alternates?.canonical).toBe('/store/java/shop')
  })

  it("tidies /store/Java/shop to the store's own link", async () => {
    api.getStore.mockResolvedValue(store())
    await expect(StoreShopPage(props('Java'))).rejects.toMatchObject({
      kind: 'permanentRedirect',
      to: '/store/java/shop',
    })
  })

  it('sends an unknown store to not-found, not an empty shop', async () => {
    api.getStore.mockResolvedValue(null)
    await expect(StoreShopPage(props('nope'))).rejects.toMatchObject({ kind: 'notFound' })
  })
})
