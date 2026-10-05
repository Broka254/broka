import { readFileSync, readdirSync } from 'node:fs'
import { resolve } from 'node:path'

import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import type { ProductCardData } from '@/lib/catalogue'
import { storeView } from '@/lib/storefront'
import type { ImageSizes, Store } from '@/lib/types'

import { cart } from '@/lib/cart'

import { AddToCart } from './AddToCart'
import { AppButton } from './AppButton'
import { CartButton } from './CartButton'
import { CartDrawer } from './CartDrawer'
import { CatalogueControls } from './CatalogueControls'
import { CategoryPills } from './CategoryPills'
import { CheckoutView } from './CheckoutView'
import { OpenInApp } from './OpenInApp'
import { ProductCard } from './ProductCard'
import { Perks } from './Perks'
import { ProductBuyBox } from './ProductBuyBox'
import { ProductGrid } from './ProductGrid'
import { ShareButtons } from './ShareButtons'
import { SiteHeader } from './SiteHeader'
import { StoreDetails } from './StoreDetails'
import { StoreHero } from './StoreHero'
import { TrustChips } from './TrustChips'
import { VisitBeacon } from './VisitBeacon'

const push = vi.fn()
vi.mock('next/navigation', () => ({ useRouter: () => ({ push }) }))

const card = (id: string, name = `Item ${id}`): ProductCardData => ({
  id,
  name,
  price: 1000,
  unit: null,
  priceLabel: 'KES 1,000',
  href: `/store/clanix/p/${id}`,
  image: null,
  imageSrcSet: null,
  emoji: '📱',
  place: 'Starehe, Nairobi',
  isAuction: false,
  condition: null,
  maxQuantity: 1,
})

// Before each, not after: resetting while the last test's components are
// still mounted would have them read the old cart straight back in.
beforeEach(() => cart.reset())

const lineOf = (p: ProductCardData) => ({
  id: p.id,
  name: p.name,
  price: p.price,
  unit: p.unit,
  image: p.image,
  emoji: p.emoji,
  href: p.href,
  max: p.maxQuantity,
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
  it('is the name in lights, what and where, the record and More - no logo square', () => {
    const { container } = render(<StoreHero view={storeView(shop())} />)
    expect(screen.getByRole('heading', { name: 'Clanix' })).toBeTruthy()
    expect(screen.getByRole('img', { name: 'Verified seller' })).toBeTruthy()
    expect(screen.getByText('Verified store')).toBeTruthy()
    expect(screen.getByText('Electronics · Starehe, Nairobi')).toBeTruthy()
    // No logo, no initial, no cover photo behind the name.
    expect(container.querySelectorAll('img')).toHaveLength(0)
    expect(screen.queryByText('C')).toBeNull()
    expect(screen.getByText('4.8')).toBeTruthy()
    expect(screen.getByText('12 deals')).toBeTruthy()
    expect(screen.getByText('3 products')).toBeTruthy()
    expect(screen.getByText('More').closest('a')!.getAttribute('href')).toBe('/store/clanix/about')
    expect(screen.queryByText('Genuine phones and accessories.')).toBeNull()
  })

  it('says whether the owner is online, or when they last were', () => {
    const owner = shop().owner!
    const { rerender } = render(<StoreHero view={storeView(shop({ owner: { ...owner, online: true, last_active: 'Active now' } }))} />)
    expect(screen.getByTestId('presence').textContent).toContain('Online now')
    rerender(<StoreHero view={storeView(shop({ owner: { ...owner, online: false, last_active: 'Active 3h ago' } }))} />)
    expect(screen.getByTestId('presence').textContent).toContain('Active 3h ago')
    // Never seen: nothing, rather than a guess.
    rerender(<StoreHero view={storeView(shop({ owner: { ...owner, online: false, last_active: null } }))} />)
    expect(screen.queryByTestId('presence')).toBeNull()
  })

  it('fans out the first product photos beside the name', () => {
    const { container } = render(
      <StoreHero view={storeView(shop())} showcase={[{ ...card('a'), image: 'https://cdn/a.webp' }, card('b')]} />,
    )
    expect([...container.querySelectorAll('img')].map((i) => i.getAttribute('src'))).toEqual(['https://cdn/a.webp'])
  })

  it('shows no tick and no rating for a new, unverified seller', () => {
    render(<StoreHero view={storeView(shop({ owner: { verified: false, rating: 5, completed_deals: 0, member_since: null } }))} />)
    expect(screen.queryByRole('img', { name: 'Verified seller' })).toBeNull()
    expect(screen.getByText('New seller')).toBeTruthy()
    expect(screen.queryByText('5.0')).toBeNull()
  })
})

describe('Perks', () => {
  it('says what buying here means, and adds verified only for a verified seller', () => {
    const { rerender } = render(<Perks verified={false} />)
    expect(screen.getByText('See it, then pay')).toBeTruthy()
    expect(screen.getByText('Pay the store directly')).toBeTruthy()
    // BROKA holds no payments while they're paused: no escrow perk.
    expect(screen.queryByText('Escrow protected')).toBeNull()
    expect(screen.queryByText(/escrow/i)).toBeNull()
    expect(screen.queryByText('Verified seller')).toBeNull()
    rerender(<Perks verified />)
    expect(screen.getByText('Verified seller')).toBeTruthy()
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

  it('tells buyers to pay the store directly after seeing the item - never to pay through BROKA', () => {
    render(<StoreDetails view={storeView(shop())} />)
    const safety = screen.getByRole('heading', { name: 'Buying safely' }).parentElement!
    expect(within(safety).getByText('Pay the store directly.')).toBeTruthy()
    expect(within(safety).getByText('See it before you pay.')).toBeTruthy()
    expect(safety.textContent).toContain('Never send a deposit to "hold" an item.')
    expect(safety.textContent).toContain('They are not run by BROKA.')
    // The old advice sent buyers to "BROKA escrow" and away from the seller.
    expect(safety.textContent).not.toMatch(/pay only through BROKA|held in escrow|never send money to a seller/i)
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
  it('says how long deals take, once there are deals to time', () => {
    const { rerender } = render(<TrustChips verified={false} completedDeals={12} rating={4.8} dealTimeMinutes={2520} />)
    expect(screen.getByText('Deals take about 2 days')).toBeTruthy()
    rerender(<TrustChips verified={false} completedDeals={0} rating={null} dealTimeMinutes={2520} />)
    expect(screen.queryByText(/Deals take/)).toBeNull()
  })
  it('renders nothing with nothing to say', () => {
    const { container } = render(<TrustChips verified={false} completedDeals={0} rating={5} />)
    expect(container.innerHTML).toBe('')
  })
})

describe('ProductCard', () => {
  it('links to the product and shows the emoji when there is no photo', () => {
    render(<ProductCard product={card('p1', 'Samsung A15')} storeId="s1" />)
    expect(screen.getAllByRole('link')[0]!.getAttribute('href')).toBe('/store/clanix/p/p1')
    expect(screen.getByText('Samsung A15')).toBeTruthy()
    expect(screen.getByText('📱')).toBeTruthy()
    // The store's location isn't repeated on every card.
    expect(screen.queryByText('Starehe, Nairobi')).toBeNull()
  })
  it('uses the photo with its sizes when there is one', () => {
    render(<ProductCard product={{ ...card('p2'), image: 'https://cdn/m.webp', imageSrcSet: 'https://cdn/t.webp 480w' }} storeId="s1" />)
    const img = screen.getByRole('img')
    expect(img.getAttribute('src')).toBe('https://cdn/m.webp')
    expect(img.getAttribute('srcset')).toBe('https://cdn/t.webp 480w')
    expect(img.getAttribute('loading')).toBe('lazy')
  })
  it('shows the condition, and an auction has no cart', () => {
    const { rerender } = render(<ProductCard product={{ ...card('p3'), condition: 'Used' }} storeId="s1" />)
    expect(screen.getByText('Used')).toBeTruthy()
    expect(screen.getByText('Add to cart')).toBeTruthy()
    rerender(<ProductCard product={{ ...card('p3'), isAuction: true }} storeId="s1" />)
    expect(screen.queryByText('Add to cart')).toBeNull()
    expect(screen.getByText('View auction')).toBeTruthy()
  })
})

describe('Add to cart', () => {
  it('becomes a stepper that stops at the stock, and - at one takes it out', () => {
    render(
      <>
        <AddToCart storeId="s1" product={{ ...card('p1'), maxQuantity: 2 }} />
        <CartButton storeId="s1" />
      </>,
    )
    fireEvent.click(screen.getByText('Add to cart'))
    expect(screen.queryByText('Add to cart')).toBeNull()
    expect(screen.getByTestId('cart-count').textContent).toBe('1')
    expect(screen.getByLabelText('Cart, 1 item')).toBeTruthy()
    fireEvent.click(screen.getByLabelText('One more'))
    expect(screen.getByTestId('cart-count').textContent).toBe('2')
    expect((screen.getByLabelText('No more available') as HTMLButtonElement).disabled).toBe(true)
    expect(screen.getByText('KES 2,000')).toBeTruthy()
    fireEvent.click(screen.getByLabelText('One less'))
    fireEvent.click(screen.getByLabelText('Remove Item p1'))
    expect(screen.getByText('Add to cart')).toBeTruthy()
    expect(screen.queryByTestId('cart-count')).toBeNull()
  })
})

describe('Cart drawer', () => {
  it('opens from the header, lists what is in the cart, and leads to checkout', () => {
    cart.add('s1', lineOf(card('p1', 'Samsung A15')))
    cart.add('s1', { ...lineOf(card('p2', 'Charger')), price: 500 })
    render(
      <>
        <CartButton storeId="s1" />
        <CartDrawer storeId="s1" storeName="Clanix" cartPath="/store/clanix/cart" />
      </>,
    )
    // The bar along the bottom, before the drawer opens.
    expect(screen.getByText('2 items in your cart')).toBeTruthy()
    fireEvent.click(screen.getByLabelText('Cart, 2 items'))
    const drawer = screen.getByRole('dialog', { name: 'Your cart (2)' })
    expect(within(drawer).getByText('Samsung A15')).toBeTruthy()
    expect(within(drawer).getByText('KES 1,500')).toBeTruthy()
    expect(within(drawer).getByText('Checkout').closest('a')!.getAttribute('href')).toBe('/store/clanix/cart')
    expect(drawer.textContent).toContain("BROKA doesn't hold payments for now: you pay the store directly")
    expect(drawer.textContent).not.toMatch(/escrow/i)
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(screen.queryByRole('dialog')).toBeNull()
  })
  it('says so when the cart is empty', () => {
    render(
      <>
        <CartButton storeId="s1" />
        <CartDrawer storeId="s1" storeName="Clanix" cartPath="/store/clanix/cart" />
      </>,
    )
    fireEvent.click(screen.getByLabelText('Cart'))
    expect(screen.getByText('Your cart is empty')).toBeTruthy()
    expect(screen.queryByText('Checkout')).toBeNull()
  })
})

describe('Search and filters', () => {
  it('search keeps the filters, and each filter is a link that keeps the rest', () => {
    const { container } = render(
      <CatalogueControls
        basePath="/store/clanix"
        storeName="Clanix"
        filters={{ q: 'tv', category: 'Electronics', sort: 'price_low', condition: null, price: null }}
      />,
    )
    const form = container.querySelector('form')!
    expect(form.getAttribute('action')).toBe('/store/clanix')
    expect([...form.querySelectorAll('input[type=hidden]')].map((i) => `${i.getAttribute('name')}=${i.getAttribute('value')}`)).toEqual([
      'category=Electronics',
      'sort=price_low',
    ])
    expect(screen.getByPlaceholderText('Search Clanix')).toBeTruthy()
    // A filter applies: the button carries a dot.
    expect(screen.getByTestId('filters-active')).toBeTruthy()
    expect(screen.getByText('Used').getAttribute('href')).toBe('/store/clanix?q=tv&category=Electronics&sort=price_low&condition=used')
    expect(screen.getByText('1K – 5K').getAttribute('href')).toBe('/store/clanix?q=tv&category=Electronics&sort=price_low&price=to5k')
    expect(screen.getByText('Price: low to high').getAttribute('aria-current')).toBe('true')
    expect(screen.getByText('Reset filters').getAttribute('href')).toBe('/store/clanix?q=tv&category=Electronics')
  })
  it('off the store page it is only a search of the store', () => {
    render(<CatalogueControls basePath="/store/clanix" storeName="Clanix" />)
    expect(screen.queryByLabelText('Filters')).toBeNull()
    expect(screen.getByRole('search')).toBeTruthy()
  })
})

describe('Product buy box', () => {
  it('adds as many as chosen, and Buy now goes to the cart', () => {
    push.mockClear()
    const line = { ...lineOf(card('p1')), max: 5 }
    render(<ProductBuyBox storeId="s1" line={line} cartPath="/store/clanix/cart" />)
    fireEvent.click(screen.getByLabelText('One more'))
    fireEvent.click(screen.getByText('Add to cart'))
    expect(cart.lines('s1')[0]!.qty).toBe(2)
    expect(screen.getByText(/2 in your cart/)).toBeTruthy()
    fireEvent.click(screen.getByText('Buy now'))
    expect(push).toHaveBeenCalledWith('/store/clanix/cart')
    // Already in the cart: Buy now doesn't add more.
    expect(cart.lines('s1')[0]!.qty).toBe(2)
  })
})

describe('Checkout', () => {
  const props = {
    storeId: 's1',
    storeName: 'Clanix',
    storePath: '/store/clanix',
    cartPath: '/store/clanix/cart',
    storeUrl: 'https://broka.co.ke/store/clanix',
  }
  it('on Android, checks out in the app with the cart in the link', () => {
    setUserAgent(ANDROID_UA)
    cart.add('s1', { ...lineOf(card('p1')), max: 3 }, 2)
    cart.add('s1', { ...lineOf(card('p2')), price: 250 })
    render(<CheckoutView {...props} />)
    expect(screen.getByTestId('cart-total').textContent).toBe('KES 2,250')
    const go = screen.getByText('Agree with the store in the BROKA app').closest('a')!
    expect(go.getAttribute('href')).toMatch(/^intent:\/\/broka\.co\.ke\/store\/clanix\/cart\?items=p1%3A2%2Cp2%3A1#Intent;/)
    expect(go.getAttribute('href')).toContain('package=com.broka.app;')
    // Who is paid, and no promise that BROKA keeps the money meanwhile.
    expect(within(screen.getByText('Payment').parentElement!).getByText('To the store directly')).toBeTruthy()
    expect(screen.queryByText('Buyer protection')).toBeNull()
    expect(document.body.textContent).not.toMatch(/BROKA holds the money|held safely|escrow protected/i)
    expect(document.body.textContent).toContain('They are not run by BROKA.')
  })
  it('elsewhere, says checkout is in the Android app - never an APK on an iPhone', () => {
    setUserAgent('Mozilla/5.0 (iPhone; CPU iPhone OS 17_0) Safari/604.1')
    cart.add('s1', lineOf(card('p1')))
    render(<CheckoutView {...props} />)
    expect(screen.getByText('Deals are agreed in the BROKA app for Android.')).toBeTruthy()
    expect(document.body.textContent).not.toMatch(/held safely/i)
    expect(screen.queryByText('Get the Android app')).toBeNull()
    expect(screen.getByText('Copy the store link')).toBeTruthy()
  })
  it('an empty cart leads back to the store', () => {
    render(<CheckoutView {...props} />)
    expect(screen.getByText('Your cart is empty')).toBeTruthy()
    expect(screen.getByText('Continue shopping').closest('a')!.getAttribute('href')).toBe('/store/clanix')
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

describe('Paying', () => {
  it('no page promises that BROKA holds or protects the payment while payments are paused', () => {
    // BROKA takes no deal payments (IN_APP_PAYMENTS_ENABLED is off), so
    // these are false - and "pay into BROKA escrow" is a scammer's line.
    // Every page takes its wording from lib/safety.ts; this reads the
    // source, so a promise can't come back in a page no test renders.
    const promises =
      /escrow protected|buyer protection|money is held|held (safely|in escrow|by BROKA)|BROKA holds (the|your) money|into BROKA escrow|protected by BROKA|pay only through BROKA|purchase (is )?protected|paid (only )?(once|when|after) you confirm/i
    const src = resolve(process.cwd(), 'src')
    const offenders = (readdirSync(src, { recursive: true }) as string[])
      .filter((f) => /\.tsx?$/.test(f) && !f.includes('.test.'))
      .filter((f) => promises.test(readFileSync(resolve(src, f), 'utf8')))
    expect(offenders).toEqual([])
  })
})

describe('Site header and footer', () => {
  it('link home with a plain <a>: "/" is the BROKA website, another deployment', () => {
    // A Next <Link> would load "/" into this site instead of going there.
    // (In tests a <Link> has no router and behaves like an <a>, so this reads
    // the source.)
    const src = resolve(process.cwd(), 'src')
    const offenders = (readdirSync(src, { recursive: true }) as string[])
      .filter((f) => f.endsWith('.tsx') && !f.includes('.test.'))
      .filter((f) => /<Link\b[^>]*\bhref=(?:"\/"|\{'\/'\})/.test(readFileSync(resolve(src, f), 'utf8')))
    expect(offenders).toEqual([])
  })
  it("show the logo from the storefront's own files", () => {
    const { container } = render(<SiteHeader />)
    expect(container.querySelector('img')?.getAttribute('src')).toBe('/store-assets/logo.png')
  })
})
