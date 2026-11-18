// The buyer's conversations with stores, as the website lists them: one per
// conversation a store page can open - a store's own thread, or the thread
// about one of its products - read from the inbox the BROKA app shows
// (GET /negotiate/inbox/{user_id}, backend routers/negotiate.py get_inbox).
//
// The inbox holds more than the website can open: chats about listings
// outside any store, the seller's side of a store the user owns, Zeno's
// messages. Those stay in the app. And it holds less than a store page
// needs: a product thread names its listing, not the listing's store. So
// each product thread's listing is looked up, and each store, through the
// same cached public reads the store pages make (lib/api.ts) - and a
// conversation whose store could not be read is left out, never guessed.
//
// No unread counts. The inbox counts what the buyer has not marked read,
// and the website marks nothing read - doing so would also send the seller
// "seen" ticks (POST /negotiate/.../mark-read), which the website has never
// sent - so a count here would stay up after the buyer had read the reply.
import { resolveImage, resolveSizes } from './images'
import { storeMessagesPath } from './links'
import type { Listing, Store } from './types'

export interface Conversation {
  /** "store:<store id>" for the store's own thread, "product:<listing id>" for one product's. */
  key: string
  store: { id: string; slug: string; name: string; logo: string | null }
  product: { id: string; name: string; image: string | null } | null
  /**
   * The newest message, as far as the website shows it: its words (null
   * for one the website doesn't show - Zeno's, a call, a deleted message),
   * whose it was, and when.
   */
  last: { text: string | null; from: 'buyer' | 'seller' | null; at: string | null }
  /** The conversation's page on the store's website. */
  href: string
}

export interface ConversationList {
  conversations: Conversation[]
  /** Some threads' stores or products could not be read just now. */
  partial: boolean
}

export interface ConversationSources {
  getListing: (id: string) => Promise<Listing | null>
  getStore: (slug: string) => Promise<Store | null>
  getStoreById: (id: string) => Promise<Store | null>
  apiUrl: string
}

/** How many of the newest threads are looked at: each may take a read of
 *  its product and store, and the oldest are in the app. */
export const MAX_THREADS = 40

/** Lookups at once: a long inbox must not open forty connections to the API. */
const LOOKUPS_AT_ONCE = 6

const ID = /^[A-Za-z0-9-]{1,64}$/
const id = (v: unknown): string | null => (typeof v === 'string' && ID.test(v) ? v : null)

export function conversationKey(storeId: string, listingId?: string | null): string {
  return listingId ? `product:${listingId}` : `store:${storeId}`
}

/** A picture fit for a list: an address, never a legacy base64 photo, which
 *  can be megabytes and would ride in every inbox read. */
function smallImage(src: string | null | undefined): string | null {
  return src && !src.startsWith('data:') ? src : null
}

function storeLogo(store: Store, apiUrl: string): string | null {
  return smallImage(resolveSizes(store.logo, apiUrl)?.thumb ?? resolveImage(store.logo_url, apiUrl))
}

/** Whether the store's messages page opens: it sends visitors elsewhere otherwise. */
function messagesOpen(store: Store): boolean {
  return store.is_active && store.orders_enabled === true
}

/** The newest message's line, as the thread on the website would show it. */
export function lastMessageOf(row: Record<string, unknown>): Conversation['last'] {
  const at = typeof row.last_message_at === 'string' ? row.last_message_at : null
  const role = row.last_role === 'buyer' || row.last_role === 'seller' ? row.last_role : null
  // Zeno's messages ("broker") are not part of the conversation the website
  // shows (api/stores/[id]/enquiries), so they are not its preview either.
  if (!role) return { text: null, from: null, at }
  const kind = typeof row.last_msg_type === 'string' ? row.last_msg_type : 'text'
  const text = typeof row.last_message === 'string' ? row.last_message.trim() : ''
  const shown =
    kind === 'text'
      ? text || null
      : kind === 'image'
        ? 'Photo'
        : kind === 'voice' || kind === 'audio'
          ? 'Voice message'
          : kind === 'file'
            ? 'Document'
            : // A call, or a message since deleted: the website's thread leaves both out.
              null
  return { text: shown ? shown.slice(0, 140) : null, from: role, at }
}

async function eachLimited<T, R>(items: readonly T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array<R>(items.length)
  let next = 0
  const worker = async () => {
    while (next < items.length) {
      const i = next++
      out[i] = await fn(items[i]!)
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker))
  return out
}

/** The conversations in an inbox response, newest first, as the website can open them. */
export async function conversationsFrom(data: unknown, sources: ConversationSources): Promise<ConversationList> {
  const rows = (Array.isArray(data) ? data : [])
    .filter((r): r is Record<string, unknown> => Boolean(r) && typeof r === 'object')
    // The buyer's side only: a store the user owns answers from the app.
    .filter((r) => r.my_role === 'buyer')
    .slice(0, MAX_THREADS)

  // One read per store, however many of its products the buyer asked about.
  const bySlug = new Map<string, Promise<Store | null>>()
  const byId = new Map<string, Promise<Store | null>>()
  const storeBySlug = (slug: string) => {
    if (!bySlug.has(slug)) bySlug.set(slug, sources.getStore(slug))
    return bySlug.get(slug)!
  }
  const storeById = (storeId: string) => {
    if (!byId.has(storeId)) byId.set(storeId, sources.getStoreById(storeId))
    return byId.get(storeId)!
  }

  let partial = false
  const found = await eachLimited(rows, LOOKUPS_AT_ONCE, async (row): Promise<Conversation | null> => {
    try {
      if (row.thread_type === 'store') {
        const storeId = id(row.store_id)
        const store = storeId ? await storeById(storeId) : null
        if (!store || !messagesOpen(store)) return null
        return {
          key: conversationKey(store.id),
          store: { id: store.id, slug: store.slug, name: store.name, logo: storeLogo(store, sources.apiUrl) },
          product: null,
          last: lastMessageOf(row),
          href: storeMessagesPath(store.slug),
        }
      }
      const listingId = id(row.listing_id)
      const listing = listingId ? await sources.getListing(listingId) : null
      // A listing outside any store is a chat in the app, with Zeno.
      if (!listing?.store_id || !listing.store_slug) return null
      const store = await storeBySlug(listing.store_slug)
      if (!store || store.id !== listing.store_id || !messagesOpen(store)) return null
      return {
        key: conversationKey(store.id, listing.id),
        store: { id: store.id, slug: store.slug, name: store.name, logo: storeLogo(store, sources.apiUrl) },
        product: {
          id: listing.id,
          name: listing.name,
          image: smallImage(resolveSizes(listing.cover ?? listing.photos?.[0] ?? null, sources.apiUrl)?.thumb),
        },
        last: lastMessageOf(row),
        href: storeMessagesPath(store.slug, listing.id),
      }
    } catch {
      // The API did not answer for this one: say the list is incomplete
      // rather than show a row that could open nowhere.
      partial = true
      return null
    }
  })

  const seen = new Set<string>()
  const conversations: Conversation[] = []
  for (const c of found) {
    if (!c || seen.has(c.key)) continue
    seen.add(c.key)
    conversations.push(c)
  }
  return { conversations, partial }
}
