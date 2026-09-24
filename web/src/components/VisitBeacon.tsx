'use client'

// Counts this page view as a store visit, for the owner's stats, from the
// visitor's own browser (so crawlers that don't run scripts aren't counted).
// A random id kept in the browser lets the API recognise a returning
// visitor within half an hour without using their IP address.
import { useEffect, useRef } from 'react'

const VISITOR_KEY = 'broka_vid'

function visitorId(): string | undefined {
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

export function VisitBeacon({ storeId, via }: { storeId: string; via?: string }) {
  const sent = useRef(false)
  useEffect(() => {
    if (sent.current) return
    sent.current = true
    void fetch(`/api/stores/${encodeURIComponent(storeId)}/visit`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        via,
        referrer: document.referrer ? document.referrer.slice(0, 500) : undefined,
        visitor: visitorId(),
      }),
      keepalive: true,
    }).catch(() => {})
  }, [storeId, via])
  return null
}
