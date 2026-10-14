'use client'

// Browser-only values for client components, read without a render on the
// server: on the server (and while hydrating) they're the fallback, then
// the real value.
import { useSyncExternalStore } from 'react'

const noSubscription = () => () => {}

export function useIsAndroid(): boolean {
  return useSyncExternalStore(noSubscription, () => /Android/i.test(navigator.userAgent), () => false)
}

/** The page's full URL, or null on the server. */
export function usePageUrl(): string | null {
  return useSyncExternalStore(noSubscription, () => window.location.href, () => null)
}

/** A sessionStorage flag (false where storage is blocked). */
export function useSessionFlag(key: string): boolean {
  return useSyncExternalStore(
    noSubscription,
    () => {
      try {
        return sessionStorage.getItem(key) === '1'
      } catch {
        return false
      }
    },
    () => false,
  )
}
