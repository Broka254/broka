// A store's cart, kept in this browser (localStorage), and the cart drawer's
// open/closed state - shared by every component on the page through one
// small store, read with useSyncExternalStore.
//
// One cart per store: an order belongs to one store, so one seller and one
// escrow (STORES_PLAN.md phase 4). Prices here are what the product card
// said when it was added: a display total, never a price anyone pays -
// checkout happens in the deal room, which reads the listing again.
import { useSyncExternalStore } from 'react'

import type { ProductCardData } from './catalogue'

export interface CartLine {
  id: string
  name: string
  /** One unit's price. */
  price: number
  unit: string | null
  image: string | null
  emoji: string
  href: string
  /** How many the listing has: the most that can be in the cart. */
  max: number
  qty: number
}

/** The cart line for a product card's data (one of it). */
export function lineFor(p: ProductCardData): Omit<CartLine, 'qty'> {
  return {
    id: p.id,
    name: p.name,
    price: p.price,
    unit: p.unit,
    // Only real image addresses: a legacy base64 photo can be megabytes,
    // and localStorage holds about five for the whole site.
    image: p.image && !p.image.startsWith('data:') ? p.image : null,
    emoji: p.emoji,
    href: p.href,
    max: p.maxQuantity,
  }
}

const PREFIX = 'broka_cart_v1_'
const MAX_LINES = 50
const EMPTY: CartLine[] = []

const carts = new Map<string, CartLine[]>()
const listeners = new Set<() => void>()
let watchingStorage = false
let drawerOpen = false
let lastAdded: { name: string; at: number } | null = null

function emit() {
  for (const l of listeners) l()
}

function clean(raw: unknown): CartLine[] {
  if (!Array.isArray(raw)) return EMPTY
  const lines: CartLine[] = []
  for (const r of raw.slice(0, MAX_LINES)) {
    if (!r || typeof r !== 'object') continue
    const l = r as Record<string, unknown>
    if (typeof l.id !== 'string' || typeof l.name !== 'string' || typeof l.price !== 'number') continue
    if (typeof l.href !== 'string' || !l.href.startsWith('/store/')) continue
    const max = Math.max(1, Math.floor(Number(l.max) || 1))
    lines.push({
      id: l.id,
      name: l.name,
      price: l.price,
      unit: typeof l.unit === 'string' ? l.unit : null,
      image: typeof l.image === 'string' ? l.image : null,
      emoji: typeof l.emoji === 'string' ? l.emoji : '🛍️',
      href: l.href,
      max,
      qty: Math.min(max, Math.max(1, Math.floor(Number(l.qty) || 1))),
    })
  }
  return lines
}

function read(storeId: string): CartLine[] {
  const cached = carts.get(storeId)
  if (cached) return cached
  let lines = EMPTY
  try {
    const raw = localStorage.getItem(PREFIX + storeId)
    if (raw) lines = clean(JSON.parse(raw))
  } catch {
    // Blocked or broken storage: an empty cart.
  }
  carts.set(storeId, lines)
  return lines
}

function write(storeId: string, lines: CartLine[]) {
  carts.set(storeId, lines)
  try {
    if (lines.length) localStorage.setItem(PREFIX + storeId, JSON.stringify(lines))
    else localStorage.removeItem(PREFIX + storeId)
  } catch {
    // Kept for this page view only.
  }
  emit()
}

function subscribe(listener: () => void) {
  listeners.add(listener)
  if (!watchingStorage && typeof window !== 'undefined') {
    watchingStorage = true
    // Another tab changed a cart: read it again.
    window.addEventListener('storage', (e) => {
      if (e.key?.startsWith(PREFIX)) {
        carts.delete(e.key.slice(PREFIX.length))
        emit()
      }
    })
  }
  return () => {
    listeners.delete(listener)
  }
}

export const cart = {
  lines: read,

  /** Adds [n] (one by default), up to what the listing has. False when
   *  none could be added. */
  add(storeId: string, line: Omit<CartLine, 'qty'>, n = 1): boolean {
    const lines = read(storeId)
    const at = lines.findIndex((l) => l.id === line.id)
    const have = at === -1 ? 0 : lines[at]!.qty
    const max = at === -1 ? Math.max(1, line.max) : lines[at]!.max
    const qty = Math.min(max, have + Math.max(1, Math.floor(n)))
    if (qty <= have) return false
    if (at === -1) {
      if (lines.length >= MAX_LINES) return false
      write(storeId, [...lines, { ...line, max, qty }])
    } else {
      write(storeId, lines.map((l, i) => (i === at ? { ...l, qty } : l)))
    }
    showAdded(line.name)
    return true
  },

  /** Zero or less takes it out; no more than the listing has. */
  setQty(storeId: string, id: string, qty: number) {
    const lines = read(storeId)
    if (qty <= 0) return cart.remove(storeId, id)
    write(storeId, lines.map((l) => (l.id === id ? { ...l, qty: Math.min(l.max, Math.floor(qty)) } : l)))
  },

  remove(storeId: string, id: string) {
    write(storeId, read(storeId).filter((l) => l.id !== id))
  },

  clear(storeId: string) {
    write(storeId, EMPTY)
  },

  /** Forgets what's in memory (tests). */
  reset() {
    carts.clear()
    drawerOpen = false
    lastAdded = null
    emit()
  },
}

export const cartCount = (lines: CartLine[]) => lines.reduce((n, l) => n + l.qty, 0)
export const cartTotal = (lines: CartLine[]) => lines.reduce((sum, l) => sum + l.price * l.qty, 0)

/** "l1:2,l2:1" - the cart for a /store/<name>/cart link the app reads. */
export const cartItemsParam = (lines: CartLine[]) => lines.map((l) => `${l.id}:${l.qty}`).join(',')

export function useCart(storeId: string): CartLine[] {
  return useSyncExternalStore(
    subscribe,
    () => read(storeId),
    () => EMPTY,
  )
}

// ── The drawer, and what was just added ──────────────────────────────────

/** How long "Added to cart" stays up, in milliseconds. */
export const ADDED_NOTE_MS = 2600

function showAdded(name: string) {
  const note = { name, at: Date.now() }
  lastAdded = note
  // Cleared from here rather than by the component, so the note's lifetime
  // doesn't depend on which components happen to be on the page.
  setTimeout(() => {
    if (lastAdded === note) {
      lastAdded = null
      emit()
    }
  }, ADDED_NOTE_MS)
}

export function openCartDrawer() {
  drawerOpen = true
  emit()
}

export function closeCartDrawer() {
  drawerOpen = false
  emit()
}

export function useCartDrawer(): boolean {
  return useSyncExternalStore(
    subscribe,
    () => drawerOpen,
    () => false,
  )
}

/** The product most recently added, for the "Added to cart" note. */
export function useLastAdded(): { name: string; at: number } | null {
  return useSyncExternalStore(
    subscribe,
    () => lastAdded,
    () => null,
  )
}
