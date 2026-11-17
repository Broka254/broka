// This browser's anonymous visitor id, and the campaign link that brought
// it to a store - for the owner's counts (visits, cart additions) and so a
// later order can be credited to the campaign. Nothing here identifies a
// person: a random id, a channel tag, a campaign token.

const VISITOR_KEY = 'broka_vid'
const ATTRIBUTION = 'broka_attr_'

export function visitorId(): string | undefined {
  try {
    let id = localStorage.getItem(VISITOR_KEY)
    if (!id || !/^[A-Za-z0-9_-]{8,64}$/.test(id)) {
      id = crypto.randomUUID()
      localStorage.setItem(VISITOR_KEY, id)
    }
    return id
  } catch {
    return undefined
  }
}

/** Remember the link's ?via= and campaign token for this store (the last
 *  campaign link wins). Read back at checkout (WebCheckout.tsx). */
export function rememberAttribution(storeId: string, via?: string, campaign?: string) {
  if (!via && !campaign) return
  try {
    localStorage.setItem(ATTRIBUTION + storeId, JSON.stringify({ via, c: campaign, at: Date.now() }))
  } catch {
    // Blocked storage: the order is simply not attributed.
  }
}

/** A product went into the cart: interest for the store's order funnel,
 *  never an order. Fire and forget - a failed count must not touch the cart. */
export function reportCartAdd(storeId: string, listingId: string) {
  if (typeof window === 'undefined') return
  try {
    const via = new URLSearchParams(window.location.search).get('via') ?? undefined
    void fetch(`/api/stores/${encodeURIComponent(storeId)}/cart-events`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ listing_id: listingId, via, visitor: visitorId() }),
      keepalive: true,
    }).catch(() => {})
  } catch {
    // Counting never matters enough to break adding to the cart.
  }
}
