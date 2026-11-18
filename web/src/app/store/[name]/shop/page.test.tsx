import { render, screen, within } from '@testing-library/react'
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

  it('marks Shop as the section in view, in the header and in the bar along the bottom of a phone', async () => {
    render(await StoreShopPage(props()))
    const sections = screen.getByRole('navigation', { name: 'Store sections' })
    expect(within(sections).getByRole('link', { name: 'Shop' }).getAttribute('aria-current')).toBe('page')
    expect(within(sections).getByRole('link', { name: 'Home' }).hasAttribute('aria-current')).toBe(false)
    const bar = screen.getByRole('navigation', { name: 'Store menu' })
    expect(within(bar).getByRole('link', { name: 'Shop' }).getAttribute('aria-current')).toBe('page')
    expect(screen.getByRole('navigation', { name: 'Breadcrumb' }).textContent).toContain('Shop')
  })

  it('an empty catalogue says so and offers a next step, never invented products', async () => {
    render(await StoreShopPage(props()))
    const empty = screen.getByTestId('catalogue-empty')
    expect(within(empty).getByRole('heading', { name: 'Nothing listed yet' })).toBeTruthy()
    // Store orders are off for this store: no link into messages that are off.
    expect(within(empty).getByRole('link', { name: 'Back to Java' }).getAttribute('href')).toBe('/store/java')
    api.getStore.mockResolvedValue(store({ orders_enabled: true }))
    render(await StoreShopPage(props()))
    expect(screen.getByRole('link', { name: /Ask Java what/ }).getAttribute('href')).toBe('/store/java/messages')
  })

  it('a search that matches nothing says so, and leads back to every product', async () => {
    render(await StoreShopPage(props('java', { q: 'drone' })))
    const empty = screen.getByTestId('catalogue-empty')
    expect(within(empty).getByRole('heading', { name: 'No products match' })).toBeTruthy()
    expect(within(empty).getByRole('link', { name: 'Show every product' }).getAttribute('href')).toBe('/store/java/shop')
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
