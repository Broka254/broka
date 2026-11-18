// The store this browser was last in, so the buyer's BROKA account pages -
// their orders and messages, from every store - can offer the way back to
// shopping there instead of a dead end. Only the store's link name and its
// name are kept (localStorage), nothing about the buyer.
const KEY = 'broka_last_store_v1'
const LINK_NAME = /^[a-z0-9]+(?:-[a-z0-9]+)*$/

export interface LastStore {
  slug: string
  name: string
}

// undefined: not read from storage yet. Kept so useSyncExternalStore gets
// the same object back until the store really changes.
let cached: LastStore | null | undefined
const listeners = new Set<() => void>()

/** Only a well-formed link name and a name of sensible length: this is read
 *  back from storage, which anything on the page could have written. */
function clean(raw: unknown): LastStore | null {
  if (!raw || typeof raw !== 'object') return null
  const { slug, name } = raw as Record<string, unknown>
  if (typeof slug !== 'string' || slug.length > 64 || !LINK_NAME.test(slug)) return null
  if (typeof name !== 'string' || !name.trim()) return null
  return { slug, name: name.trim().slice(0, 80) }
}

export function lastStore(): LastStore | null {
  if (cached !== undefined) return cached
  try {
    const raw = localStorage.getItem(KEY)
    cached = raw ? clean(JSON.parse(raw)) : null
  } catch {
    // Blocked or broken storage: no way back to offer.
    cached = null
  }
  return cached
}

export function rememberStore(store: LastStore) {
  const next = clean(store)
  if (!next) return
  const now = lastStore()
  if (now && now.slug === next.slug && now.name === next.name) return
  cached = next
  try {
    localStorage.setItem(KEY, JSON.stringify(next))
  } catch {
    // Kept for this page view only.
  }
  for (const l of listeners) l()
}

export function subscribeLastStore(listener: () => void) {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

/** Tests: forget what this page knows. */
export function resetLastStore() {
  cached = undefined
}
