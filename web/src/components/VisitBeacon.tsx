'use client'

// Counts this page view as a store visit, for the owner's stats, from the
// visitor's own browser (so crawlers that don't run scripts aren't counted).
// A random id kept in the browser lets the API recognise a returning
// visitor within half an hour without using their IP address.
import { useEffect, useRef } from 'react'

import { rememberAttribution, visitorId } from '@/lib/visitor'

export function VisitBeacon({
  storeId,
  via,
  campaign,
  productView = false,
}: {
  storeId: string
  via?: string
  campaign?: string
  /** The page is a product, so a campaign also gets the product view. */
  productView?: boolean
}) {
  const sent = useRef(false)
  useEffect(() => {
    if (sent.current) return
    sent.current = true
    // A campaign link's token is kept for this store, so an order sent
    // later from the cart is credited to the campaign that brought it.
    rememberAttribution(storeId, via, campaign)
    void fetch(`/api/stores/${encodeURIComponent(storeId)}/visit`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        via,
        campaign,
        product_view: productView || undefined,
        referrer: document.referrer ? document.referrer.slice(0, 500) : undefined,
        visitor: visitorId(),
      }),
      keepalive: true,
    }).catch(() => {})
  }, [storeId, via, campaign, productView])
  return null
}
