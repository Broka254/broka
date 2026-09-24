import { act, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'

import type { ProductCardData } from '@/lib/catalogue'

import { AppButton } from './AppButton'
import { CategoryPills } from './CategoryPills'
import { OpenInApp } from './OpenInApp'
import { ProductCard } from './ProductCard'
import { ProductGrid } from './ProductGrid'
import { ShareButtons } from './ShareButtons'
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
