import { describe, expect, it, vi } from 'vitest'

import { type ConversationSources, conversationsFrom, lastMessageOf, MAX_THREADS } from './conversations'
import type { Listing, Store } from './types'

const store = (over: Partial<Store> = {}) =>
  ({
    id: 's1',
    name: 'Clanix',
    slug: 'clanix',
    is_active: true,
    orders_enabled: true,
    logo: { id: 'lg', thumb: '/media/lg/thumb.webp', medium: '/media/lg/medium.webp', large: '/media/lg/large.webp' },
    logo_url: null,
    ...over,
  }) as Store

const listing = (over: Partial<Listing> = {}) =>
  ({
    id: 'l1',
    name: 'Samsung A15',
    store_id: 's1',
    store_slug: 'clanix',
    cover: { id: 'c1', thumb: 'https://cdn/c1/thumb.webp', medium: 'https://cdn/c1/medium.webp', large: 'https://cdn/c1/large.webp' },
    photos: [],
    ...over,
  }) as Listing

/** An inbox row as GET /negotiate/inbox/{id} sends it (routers/negotiate.py get_inbox). */
const storeRow = (over: Record<string, unknown> = {}) => ({
  thread_type: 'store',
  store_id: 's1',
  listing_id: null,
  my_role: 'buyer',
  last_message: 'Yes, two left.',
  last_role: 'seller',
  last_msg_type: 'text',
  last_message_at: '2026-11-18T05:00:00Z',
  unread: 3,
  ...over,
})
const productRow = (over: Record<string, unknown> = {}) => ({
  listing_id: 'l1',
  my_role: 'buyer',
  last_message: 'Is it in stock?',
  last_role: 'buyer',
  last_msg_type: 'text',
  last_message_at: '2026-11-18T04:00:00Z',
  unread: 0,
  ...over,
})

function sources(over: Partial<ConversationSources> = {}): ConversationSources {
  return {
    getListing: vi.fn(async (id: string) => (id === 'l1' ? listing() : null)),
    getStore: vi.fn(async (slug: string) => (slug === 'clanix' ? store() : null)),
    getStoreById: vi.fn(async (id: string) => (id === 's1' ? store() : null)),
    apiUrl: 'https://api.test',
    ...over,
  }
}

describe("the buyer's conversations with stores", () => {
  it("lists a store's own thread and a product's thread, newest first, each opening on its store's messages page", async () => {
    const { conversations, partial } = await conversationsFrom([storeRow(), productRow()], sources())
    expect(partial).toBe(false)
    expect(conversations).toEqual([
      {
        key: 'store:s1',
        store: { id: 's1', slug: 'clanix', name: 'Clanix', logo: 'https://api.test/media/lg/thumb.webp' },
        product: null,
        last: { text: 'Yes, two left.', from: 'seller', at: '2026-11-18T05:00:00Z' },
        href: '/store/clanix/messages',
      },
      {
        key: 'product:l1',
        store: { id: 's1', slug: 'clanix', name: 'Clanix', logo: 'https://api.test/media/lg/thumb.webp' },
        product: { id: 'l1', name: 'Samsung A15', image: 'https://cdn/c1/thumb.webp' },
        last: { text: 'Is it in stock?', from: 'buyer', at: '2026-11-18T04:00:00Z' },
        href: '/store/clanix/messages?product=l1',
      },
    ])
  })

  it('carries no unread count: the website marks nothing read, so one would never go down', async () => {
    const { conversations } = await conversationsFrom([storeRow({ unread: 7 })], sources())
    expect(JSON.stringify(conversations)).not.toMatch(/unread/)
  })

  it('reads each store once, however many of its products the buyer asked about', async () => {
    const src = sources({
      getListing: vi.fn(async (id: string) => listing({ id, name: `Product ${id}` })),
    })
    await conversationsFrom([productRow({ listing_id: 'l1' }), productRow({ listing_id: 'l2' }), productRow({ listing_id: 'l3' })], src)
    expect(src.getListing).toHaveBeenCalledTimes(3)
    expect(src.getStore).toHaveBeenCalledTimes(1)
  })

  it("leaves out what the website can't open: the seller's side, listings outside stores, stores without web messages", async () => {
    const src = sources({
      getListing: vi.fn(async (id: string) =>
        id === 'outside' ? listing({ id, store_id: null, store_slug: null }) : id === 'other' ? listing({ id, store_slug: 'closed' }) : listing(),
      ),
      getStore: vi.fn(async (slug: string) => (slug === 'closed' ? store({ id: 's1', slug: 'closed', orders_enabled: false }) : store())),
      getStoreById: vi.fn(async () => store({ is_active: false })),
    })
    const { conversations } = await conversationsFrom(
      [
        productRow({ my_role: 'seller' }),
        productRow({ listing_id: 'outside' }),
        productRow({ listing_id: 'other' }),
        storeRow(),
      ],
      src,
    )
    expect(conversations).toEqual([])
  })

  it("never puts a product under a store that isn't its own", async () => {
    const src = sources({ getStore: vi.fn(async () => store({ id: 's-other' })) })
    const { conversations } = await conversationsFrom([productRow()], src)
    expect(conversations).toEqual([])
  })

  it('says the list is incomplete when a store or product could not be read, instead of guessing', async () => {
    const src = sources({
      getListing: vi.fn(async () => {
        throw new Error('API asleep')
      }),
    })
    const { conversations, partial } = await conversationsFrom([productRow(), storeRow()], src)
    expect(partial).toBe(true)
    expect(conversations.map((c) => c.key)).toEqual(['store:s1'])
  })

  it('looks at the newest threads only, and shows each conversation once', async () => {
    const rows = Array.from({ length: MAX_THREADS + 5 }, () => storeRow())
    const src = sources()
    const { conversations } = await conversationsFrom(rows, src)
    expect(conversations).toHaveLength(1)
    expect(src.getStoreById).toHaveBeenCalledTimes(1)
    expect((await conversationsFrom({ not: 'a list' }, sources())).conversations).toEqual([])
  })

  it("never ships a legacy base64 photo in the list: it can be megabytes", async () => {
    const src = sources({
      getStoreById: vi.fn(async () => store({ logo: null, logo_url: `data:image/jpeg;base64,${'A'.repeat(64)}` })),
    })
    const { conversations } = await conversationsFrom([storeRow()], src)
    expect(conversations[0]!.store.logo).toBeNull()
  })
})

describe("a conversation's last line", () => {
  it("is the website's own: no Zeno, no call or deleted message, and media by name", () => {
    expect(lastMessageOf(storeRow({ last_role: 'broker', last_message: 'Private note from Zeno' }))).toEqual({
      text: null,
      from: null,
      at: '2026-11-18T05:00:00Z',
    })
    expect(lastMessageOf(storeRow({ last_msg_type: 'call', last_message: 'missed' })).text).toBeNull()
    expect(lastMessageOf(storeRow({ last_msg_type: 'deleted', last_message: 'Message deleted' })).text).toBeNull()
    expect(lastMessageOf(storeRow({ last_msg_type: 'image', last_message: '📷 Photo' })).text).toBe('Photo')
    expect(lastMessageOf(storeRow({ last_message: `  ${'x'.repeat(300)} ` })).text).toHaveLength(140)
  })
})
