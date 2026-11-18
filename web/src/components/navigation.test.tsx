import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import { cart } from '@/lib/cart'
import { APP_DOWNLOAD_URL } from '@/lib/config'
import { resetLastStore } from '@/lib/last-store'
import { storeView } from '@/lib/storefront'
import type { Store } from '@/lib/types'
import { storeFixture } from '@/test/fixtures'

import { AccountHeader } from './AccountHeader'
import { calmBackground } from './BrandBackground'
import { CartDrawer } from './CartDrawer'
import { StoreHeader } from './StoreHeader'

vi.mock('next/navigation', () => ({ useRouter: () => ({ push: vi.fn() }), usePathname: () => '/' }))

beforeEach(() => {
  cart.reset()
  resetLastStore()
})

/** A store with store orders on: messages and orders on the website. */
const view = (over: Partial<Store> = {}) => storeView(storeFixture({ orders_enabled: true, ...over }))

const sections = () => screen.getByRole('navigation', { name: 'Store sections' })
const bottomBar = () => screen.getByRole('navigation', { name: 'Store menu' })
const linksOf = (el: HTMLElement) =>
  within(el)
    .getAllByRole('link')
    .map((a) => [a.textContent?.trim(), a.getAttribute('href')])
const currentIn = (el: HTMLElement) =>
  within(el)
    .getAllByRole('link')
    .filter((a) => a.hasAttribute('aria-current'))
    .map((a) => [a.textContent?.trim(), a.getAttribute('aria-current')])

const line = {
  id: 'p1',
  name: 'Samsung A15',
  price: 15000,
  unit: null,
  image: null,
  emoji: '📱',
  href: '/store/clanix/p/p1',
  max: 3,
}

describe("a store's navigation", () => {
  it.each([
    ['home', 'Home'],
    ['shop', 'Shop'],
    ['messages', 'Messages'],
    ['about', 'About'],
  ] as const)('on the %s page, %s is the one section marked as the page the buyer is on', (page, label) => {
    render(<StoreHeader view={view()} active={page} />)
    expect(currentIn(sections())).toEqual([[label, 'page']])
  })

  it('on a product, Shop stays marked as the section the buyer is in - and leads back to the catalogue', () => {
    render(<StoreHeader view={view()} active="product" />)
    expect(currentIn(sections())).toEqual([['Shop', 'true']])
    expect(within(sections()).getByRole('link', { name: 'Shop' }).getAttribute('href')).toBe('/store/clanix/shop')
  })

  it("links every section to the store's own pages, and Your orders apart from them, to the buyer's account", () => {
    render(<StoreHeader view={view()} active="home" />)
    expect(linksOf(sections())).toEqual([
      ['Home', '/store/clanix'],
      ['Shop', '/store/clanix/shop'],
      ['Messages', '/store/clanix/messages'],
      ['About', '/store/clanix/about'],
      ['Your orders', '/store/orders'],
    ])
    // The store stays the brand, on every page.
    expect(screen.getByRole('link', { name: 'Clanix home' }).getAttribute('href')).toBe('/store/clanix')
    // Searching from any page searches the catalogue.
    expect(screen.getByRole('search').getAttribute('action')).toBe('/store/clanix/shop')
  })

  it('without store orders there is no Messages or orders link: those are in the app', () => {
    render(<StoreHeader view={storeView(storeFixture())} active="home" />)
    expect(linksOf(sections()).map(([label]) => label)).toEqual(['Home', 'Shop', 'About'])
    expect(within(bottomBar()).queryByRole('link', { name: 'Messages' })).toBeNull()
    expect(within(bottomBar()).queryByRole('link', { name: 'Orders' })).toBeNull()
  })
})

describe('the bar along the bottom of a phone', () => {
  it('keeps Home, Shop, Messages, the cart and the orders within reach, with the page marked', () => {
    render(<StoreHeader view={view()} active="shop" />)
    expect(linksOf(bottomBar())).toEqual([
      ['Home', '/store/clanix'],
      ['Shop', '/store/clanix/shop'],
      ['Messages', '/store/clanix/messages'],
      ['Orders', '/store/orders'],
    ])
    expect(currentIn(bottomBar())).toEqual([['Shop', 'page']])
  })

  it('shows how many items the cart holds, and opens the cart', () => {
    cart.add('s1', line, 2)
    render(
      <>
        <StoreHeader view={view()} active="product" />
        <CartDrawer storeId="s1" storeName="Clanix" cartPath="/store/clanix/cart" />
      </>,
    )
    const tab = within(bottomBar()).getByRole('button', { name: 'Cart, 2 items' })
    expect(within(tab).getByTestId('bottom-nav-cart-count').textContent).toBe('2')
    fireEvent.click(tab)
    expect(screen.getByRole('dialog', { name: 'Your cart (2)' })).toBeTruthy()
  })

  it('on the cart page the Cart tab is that page, not a drawer over it', () => {
    render(<StoreHeader view={view()} active="cart" />)
    const tab = within(bottomBar()).getByRole('link', { name: 'Cart' })
    expect(tab.getAttribute('href')).toBe('/store/clanix/cart')
    expect(tab.getAttribute('aria-current')).toBe('page')
  })

  it('steps out of the way while the buyer types, so it never rides up on the keyboard over the field', async () => {
    render(<StoreHeader view={view()} active="shop" />)
    const search = screen.getByPlaceholderText('Search Clanix')
    fireEvent.focusIn(search)
    expect(bottomBar().getAttribute('data-away')).toBe('true')
    fireEvent.focusOut(search)
    await waitFor(() => expect(bottomBar().hasAttribute('data-away')).toBe(false))
  })

  it('is not on the messages page: on a phone that page is a chat screen with a header of its own', () => {
    render(<StoreHeader view={view()} active="messages" />)
    expect(screen.queryByRole('navigation', { name: 'Store menu' })).toBeNull()
  })

  it('a paused store has no cart and no messages to offer', () => {
    render(<StoreHeader view={view({ is_active: false })} active="home" />)
    expect(within(bottomBar()).queryByRole('button', { name: /Cart/ })).toBeNull()
    expect(within(bottomBar()).queryByRole('link', { name: 'Messages' })).toBeNull()
    expect(within(bottomBar()).getByRole('link', { name: 'Orders' })).toBeTruthy()
  })
})

describe("the buyer's account pages", () => {
  it("wear BROKA's header, not a store's: orders from several stores are no one store's page", () => {
    render(<AccountHeader active="orders" />)
    expect(screen.getByRole('link', { name: 'BROKA home' }).getAttribute('href')).toBe('/')
    const tabs = screen.getByRole('navigation', { name: 'Your account' })
    expect(linksOf(tabs)).toEqual([
      ['Orders', '/store/orders'],
      ['Messages', '/store/account/messages'],
    ])
    expect(currentIn(tabs)).toEqual([['Orders', 'page']])
    expect(screen.queryByRole('navigation', { name: 'Store sections' })).toBeNull()
  })

  it('an order is inside Orders; the messages page is Messages', () => {
    const { rerender } = render(<AccountHeader active="order" />)
    expect(currentIn(screen.getByRole('navigation', { name: 'Your account' }))).toEqual([['Orders', 'true']])
    rerender(<AccountHeader active="messages" />)
    expect(currentIn(screen.getByRole('navigation', { name: 'Your account' }))).toEqual([['Messages', 'page']])
  })

  it('lead back to the store the buyer was shopping in, and to the app before they have been in one', () => {
    const { unmount } = render(<AccountHeader active="orders" />)
    expect(screen.getByRole('link', { name: 'Get the app' }).getAttribute('href')).toBe(APP_DOWNLOAD_URL)
    unmount()

    // Any page of a store remembers it.
    render(<StoreHeader view={view()} active="shop" />)
    cleanup()
    render(<AccountHeader active="orders" />)
    const back = screen.getByTestId('continue-shopping')
    expect(back.textContent).toBe('Back to Clanix')
    expect(back.getAttribute('href')).toBe('/store/clanix')
  })
})

describe('the moving background', () => {
  it('keeps still where the buyer reads and types: a conversation, the cart, their orders and messages', () => {
    for (const path of ['/store/clanix/messages', '/store/clanix/cart', '/store/orders', '/store/orders/o1', '/store/account/messages']) {
      expect(calmBackground(path)).toBe(true)
    }
    for (const path of ['/store/clanix', '/store/clanix/shop', '/store/clanix/p/l1', '/store/clanix/about', '/', null]) {
      expect(calmBackground(path)).toBe(false)
    }
  })
})
