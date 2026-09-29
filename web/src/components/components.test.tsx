import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'

import type { ProductCardData } from '@/lib/catalogue'
import { storeView } from '@/lib/storefront'
import type { ImageSizes, Store } from '@/lib/types'

import { AppButton } from './AppButton'
import { CategoryPills } from './CategoryPills'
import { OpenInApp } from './OpenInApp'
import { ProductCard } from './ProductCard'
import { ProductGrid } from './ProductGrid'
import { ShareButtons } from './ShareButtons'
import { StoreDetails } from './StoreDetails'
import { StoreHero } from './StoreHero'
import { TrustChips } from './TrustChips'
import { VisitBeacon } from './VisitBeacon'

vi.mock('next/navigation', () => ({ useRouter: () => ({ push: vi.fn() }) }))

const card = (id: string, name = `Item ${id}`): ProductCardData => ({
  id,
  name,
  priceLabel: 'KES 1,000',
  href: `/store/clanix/p/${id}`,
  image: null,
  imageSrcSet: null,
  emoji: '📱',
  place: 'Starehe, Nairobi',
  isAuction: false,
})

const ANDROID_UA = 'Mozilla/5.0 (Linux; Android 14; SM-A145F) AppleWebKit/537.36 Chrome/124 Mobile Safari/537.36'

function setUserAgent(ua: string) {
  vi.spyOn(window.navigator, 'userAgent', 'get').mockReturnValue(ua)
}

const sizes = (id: string): ImageSizes => ({
  id,
  thumb: `https://media.broka.co.ke/img/${id}/thumb.webp`,
  medium: `https://media.broka.co.ke/img/${id}/medium.webp`,
  large: `https://media.broka.co.ke/img/${id}/large.webp`,
})

const shop = (over: Partial<Store> = {}): Store => ({
  id: 's1',
  name: 'Clanix',
  slug: 'clanix',
  url: 'https://broka.co.ke/store/clanix',
  category: 'Electronics',
  description: 'Genuine phones and accessories.',
  country: 'Kenya',
  county: 'Nairobi',
  subcounty: 'Starehe',
  location_description: 'Moi Avenue, Bazaar Plaza',
  business_email: 'sales@clanix.co.ke',
  business_email_verified: true,
  logo: null,
  cover: sizes('c1'),
  photo_images: [sizes('p1')],
  logo_url: null,
  photos: [],
  owner: { name: 'Jane Wanjiru', verified: true, rating: 4.84, completed_deals: 12, member_since: '2025-01-10T00:00:00' },
  is_active: true,
  listing_count: 3,
  created_at: '2026-09-02T08:00:00',
  ...over,
})

describe('StoreHero', () => {
  it('is the name, what and where, and More details - no cover photo, no record chips', () => {
    const { container } = render(<StoreHero view={storeView(shop())} />)
    expect(screen.getByRole('heading', { name: /^Clanix/ })).toBeTruthy()
    expect(screen.getByRole('img', { name: 'Verified seller' })).toBeTruthy()
    expect(screen.getByText('Electronics · Starehe, Nairobi')).toBeTruthy()
    expect(container.querySelectorAll('img')).toHaveLength(0)
    expect(screen.getByText('ⓘ More details ›').getAttribute('href')).toBe('/store/clanix/about')
    // The seller's record and what the store says about itself are on the
    // Store details page.
    for (const text of ['12 deals done', '4.8', 'On BROKA since 2025', 'Genuine phones and accessories.']) {
      expect(screen.queryByText(text)).toBeNull()
    }
  })

  it('shows no tick for a seller who is not verified', () => {
    render(<StoreHero view={storeView(shop({ owner: { verified: false, rating: null, completed_deals: 0, member_since: null } }))} />)
    expect(screen.queryByRole('img', { name: 'Verified seller' })).toBeNull()
  })
})

describe('StoreDetails', () => {
  it("shows the seller's record, the photos, where the shop is and how to reach it", () => {
    render(<StoreDetails view={storeView(shop())} />)
    const photos = screen.getAllByRole('img')
    expect(photos.map((i) => i.getAttribute('src'))).toEqual([
      'https://media.broka.co.ke/img/c1/medium.webp',
      'https://media.broka.co.ke/img/p1/medium.webp',
    ])
    expect(screen.getByText('Open')).toBeTruthy()
    expect(screen.getByText('Genuine phones and accessories.')).toBeTruthy()
    expect(screen.getByText('Jane Wanjiru')).toBeTruthy()
    expect(screen.getByText('✓ Verified seller')).toBeTruthy()
    // Deals done, rating and the year joined, each in its own tile.
    for (const [label, value] of [
      ['Deals done', '12'],
      ['Rating', '4.8'],
      ['On BROKA since', '2025'],
    ] as const) {
      expect(within(screen.getByText(label).parentElement!).getByText(value)).toBeTruthy()
    }
    expect(screen.getByText('📍 Starehe, Nairobi')).toBeTruthy()
    expect(screen.getByText('Moi Avenue, Bazaar Plaza')).toBeTruthy()
    expect(screen.getByText('Find it on the map').getAttribute('href')).toBe(
      'https://www.google.com/maps/search/?api=1&query=Moi%20Avenue%2C%20Bazaar%20Plaza%2C%20Starehe%2C%20Nairobi%2C%20Kenya',
    )
    expect(screen.getByText('sales@clanix.co.ke').getAttribute('href')).toBe('mailto:sales@clanix.co.ke')
    expect(screen.getByText('September 2026')).toBeTruthy()
    expect(screen.getByText('3 products on sale')).toBeTruthy()
  })

  it('never shows an unverified email, a rating without deals, or photos it does not have', () => {
    render(
      <StoreDetails
        view={storeView(
          shop({
            cover: null,
            photo_images: [],
            business_email_verified: false,
            is_active: false,
            owner: { verified: false, rating: 5, completed_deals: 0, member_since: null },
          }),
        )}
      />,
    )
    expect(screen.queryAllByRole('img')).toEqual([])
    expect(screen.queryByText('sales@clanix.co.ke')).toBeNull()
    expect(within(screen.getByText('No rating yet').parentElement!).getByText('New')).toBeTruthy()
    expect(screen.queryByText('5.0')).toBeNull()
    expect(within(screen.getByText('On BROKA since').parentElement!).getByText('–')).toBeTruthy()
    expect(screen.getByText('Not verified yet')).toBeTruthy()
    // An API from before the owner's name was sent.
    expect(screen.getByText('The owner of Clanix')).toBeTruthy()
    expect(screen.getByText('Taking a break')).toBeTruthy()
  })
})

describe('TrustChips', () => {
  it('shows a rating only when there are deals behind it', () => {
    const { rerender } = render(<TrustChips verified completedDeals={0} rating={5} memberSince="2025-03-01" />)
    expect(screen.getByText('Verified seller')).toBeTruthy()
    expect(screen.queryByText('5.0')).toBeNull()
    expect(screen.getByText('On BROKA since 2025')).toBeTruthy()
    rerender(<TrustChips verified={false} completedDeals={12} rating={4.84} />)
    expect(screen.getByText('12 deals done')).toBeTruthy()
    expect(screen.getByText('4.8')).toBeTruthy()
    expect(screen.queryByText('Verified seller')).toBeNull()
  })
  it('renders nothing with nothing to say', () => {
    const { container } = render(<TrustChips verified={false} completedDeals={0} rating={5} />)
    expect(container.innerHTML).toBe('')
  })
})

describe('ProductCard', () => {
  it('links to the product and shows the emoji when there is no photo', () => {
    render(<ProductCard product={card('p1', 'Samsung A15')} />)
    const link = screen.getByRole('link')
    expect(link.getAttribute('href')).toBe('/store/clanix/p/p1')
    expect(screen.getByText('Samsung A15')).toBeTruthy()
    expect(screen.getByText('📱')).toBeTruthy()
  })
  it('uses the photo with its sizes when there is one', () => {
    render(<ProductCard product={{ ...card('p2'), image: 'https://cdn/m.webp', imageSrcSet: 'https://cdn/t.webp 480w' }} />)
    const img = screen.getByRole('img')
    expect(img.getAttribute('src')).toBe('https://cdn/m.webp')
    expect(img.getAttribute('srcset')).toBe('https://cdn/t.webp 480w')
    expect(img.getAttribute('loading')).toBe('lazy')
  })
})

describe('CategoryPills', () => {
  it('keeps the search and sort when switching category, and marks the current one', () => {
    render(
      <CategoryPills
        basePath="/store/clanix"
        categories={[
          { name: 'Electronics', count: 12 },
          { name: 'Home & Furniture', count: 3 },
        ]}
        total={15}
        filters={{ q: 'tv', category: 'Electronics', sort: 'price_low' }}
      />,
    )
    const links = screen.getAllByRole('link')
    expect(links.map((l) => l.getAttribute('href'))).toEqual([
      '/store/clanix?q=tv&sort=price_low',
      '/store/clanix?q=tv&category=Electronics&sort=price_low',
      '/store/clanix?q=tv&category=Home+%26+Furniture&sort=price_low',
    ])
    expect(links[1]!.getAttribute('aria-current')).toBe('page')
    expect(screen.getByText('15')).toBeTruthy()
  })
})

describe('ProductGrid', () => {
  it('loads more pages through the storefront API and stops at the last', async () => {
    const fetchMock = vi.fn(async () => new Response(JSON.stringify([card('p3'), card('p1')]), { status: 200 }))
    vi.stubGlobal('fetch', fetchMock)
    render(
      <ProductGrid
        storeId="s1"
        slug="clanix"
        filters={{ q: 'tv', category: null, sort: 'newest' }}
        initial={[card('p1'), card('p2')]}
        pageSize={2}
      />,
    )
    fireEvent.click(screen.getByText('Show more products'))
    await waitFor(() => expect(screen.getAllByRole('link')).toHaveLength(3))
    expect(fetchMock).toHaveBeenCalledWith('/api/stores/s1/listings?slug=clanix&offset=2&q=tv&sort=newest')
    // A page with a duplicate means fewer than a full page of new items.
    expect(screen.getByText('Show more products')).toBeTruthy()
  })
  it('offers a retry when loading fails', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response('', { status: 503 })))
    render(<ProductGrid storeId="s1" slug="clanix" filters={{ q: '', category: null, sort: 'featured' }} initial={[card('a'), card('b')]} pageSize={2} />)
    fireEvent.click(screen.getByText('Show more products'))
    await waitFor(() => expect(screen.getByText('Try again')).toBeTruthy())
  })
})

describe('VisitBeacon', () => {
  it('counts one visit with a stable browser visitor id', async () => {
    const fetchMock = vi.fn(async () => new Response(null, { status: 204 }))
    vi.stubGlobal('fetch', fetchMock)
    const { rerender } = render(<VisitBeacon storeId="s1" via="tiktok" />)
    rerender(<VisitBeacon storeId="s1" via="tiktok" />)
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1))
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
    expect(url).toBe('/api/stores/s1/visit')
    const body = JSON.parse(String(init.body))
    expect(body.via).toBe('tiktok')
    expect(body.visitor).toMatch(/^[A-Za-z0-9_-]{8,64}$/)
    expect(localStorage.getItem('broka_vid')).toBe(body.visitor)
  })
})

describe('ShareButtons', () => {
  it('shares to WhatsApp with a tagged link and counts it', () => {
    const fetchMock = vi.fn(async () => new Response(null, { status: 204 }))
    vi.stubGlobal('fetch', fetchMock)
    render(<ShareButtons storeId="s1" url="https://broka.co.ke/store/clanix" title="Clanix" />)
    const wa = screen.getByText('WhatsApp')
    expect(decodeURIComponent(wa.getAttribute('href')!)).toBe(
      'https://wa.me/?text=Clanix: https://broka.co.ke/store/clanix?via=whatsapp',
    )
    fireEvent.click(wa)
    expect(JSON.parse(String((fetchMock.mock.calls[0] as unknown as [string, RequestInit])[1].body))).toEqual({
      channel: 'whatsapp',
    })
  })
  it('copies the link where there is no share sheet', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(null, { status: 204 })))
    const writeText = vi.fn(async () => {})
    Object.defineProperty(navigator, 'share', { value: undefined, configurable: true })
    Object.defineProperty(navigator, 'clipboard', { value: { writeText }, configurable: true })
    render(<ShareButtons storeId="s1" url="https://broka.co.ke/store/clanix" title="Clanix" />)
    await act(async () => {
      fireEvent.click(screen.getByText('Share'))
    })
    expect(writeText).toHaveBeenCalledWith('https://broka.co.ke/store/clanix')
    expect(screen.getByText('Link copied ✓')).toBeTruthy()
  })
})

describe('Opening the app', () => {
  it('Android visitors get an Open banner into the app, which they can dismiss', () => {
    setUserAgent(ANDROID_UA)
    render(<OpenInApp />)
    const open = screen.getByText('Open')
    expect(open.getAttribute('href')).toMatch(/^intent:\/\/localhost.*package=com\.broka\.app;/)
    fireEvent.click(screen.getByLabelText('Dismiss'))
    expect(screen.queryByText('Open')).toBeNull()
    expect(sessionStorage.getItem('broka_open_in_app_dismissed')).toBe('1')
  })
  it('other visitors see no banner, and the app button is the download', () => {
    setUserAgent('Mozilla/5.0 (iPhone; CPU iPhone OS 17_0) Safari/604.1')
    render(
      <>
        <OpenInApp />
        <AppButton label="Get it" />
      </>,
    )
    expect(screen.queryByText('Open')).toBeNull()
    expect(screen.getByText('Get it').getAttribute('href')).toMatch(/broka-release\.apk$/)
  })
})
