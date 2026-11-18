'use client'

// Remembering the store a buyer is in (every store page renders
// RememberStore), and offering the way back to it from their BROKA account
// pages (ContinueShopping), which list orders and messages from every store
// and so belong to none of them.
import Link from 'next/link'
import { useEffect, useSyncExternalStore } from 'react'

import { APP_DOWNLOAD_URL } from '@/lib/config'
import { lastStore, rememberStore, subscribeLastStore } from '@/lib/last-store'
import { storePath } from '@/lib/links'

import { Icon } from './Icon'

export function RememberStore({ slug, name }: { slug: string; name: string }) {
  useEffect(() => {
    rememberStore({ slug, name })
  }, [slug, name])
  return null
}

/** "Back to Clanix", or - for a buyer who came straight to their orders -
 *  the app, as BROKA's own header offers. */
export function ContinueShopping({ className }: { className?: string }) {
  const store = useSyncExternalStore(subscribeLastStore, lastStore, () => null)
  if (!store) {
    return (
      <a className={className} href={APP_DOWNLOAD_URL} rel="nofollow">
        Get the app
      </a>
    )
  }
  return (
    <Link href={storePath(store.slug)} className={className} data-testid="continue-shopping">
      <Icon name="back" size={16} />
      <span>
        Back to <strong>{store.name}</strong>
      </span>
    </Link>
  )
}
