// The sections of a store's website and where each one is, as its
// navigation shows them: the row under the header on a wide screen
// (StoreHeader), the bar along the bottom of a phone (StoreBottomNav) and
// the footer. One list, so the three can never disagree about what a store
// offers or which page the buyer is on.
import { storeCartPath, storeDetailsPath, storeMessagesPath, storePath, storeShopPath } from './links'
import { ordersPath } from './orders'
import type { Store } from './types'

export type StoreSection = 'home' | 'shop' | 'messages' | 'about' | 'cart'

/** What a page is: one of the sections, or a product - which is in the shop. */
export type StorePage = StoreSection | 'product'

export interface StorePaths {
  home: string
  shop: string
  about: string
  /** Null while the store is paused: it sells nothing then. */
  cart: string | null
  /** Messaging and orders come with store orders (STORE_ORDERS.md): without
   *  them the store's pages offer the app instead, and the navigation has
   *  no links into features that are off. */
  messages: string | null
  /** The buyer's orders from every store: their BROKA account. */
  orders: string | null
}

export function storePaths(store: Pick<Store, 'slug' | 'is_active' | 'orders_enabled'>): StorePaths {
  const commerce = store.orders_enabled === true
  return {
    home: storePath(store.slug),
    shop: storeShopPath(store.slug),
    about: storeDetailsPath(store.slug),
    cart: store.is_active ? storeCartPath(store.slug) : null,
    // The messages page sends visitors of a paused store to its home.
    messages: commerce && store.is_active ? storeMessagesPath(store.slug) : null,
    orders: commerce ? ordersPath : null,
  }
}

/** The section a page belongs to. */
export function sectionOf(page: StorePage): StoreSection {
  return page === 'product' ? 'shop' : page
}

/**
 * aria-current for a section's link: "page" on that section's own page,
 * "true" on a page inside it (a product, inside the shop) - marked as where
 * the buyer is, without claiming the link goes to the page they are on.
 */
export function currentMark(section: StoreSection, page: StorePage): 'page' | 'true' | undefined {
  if (sectionOf(page) !== section) return undefined
  return page === section ? 'page' : 'true'
}
