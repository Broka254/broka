'use client'

// Sharing a store or product from the web: WhatsApp (how most people here
// share), and the system share sheet or a copied link. Each tap is counted
// for the store owner's stats.
import { useState } from 'react'

import { Icon } from './Icon'
import shop from './shop.module.css'
import styles from './store.module.css'

function withVia(url: string, via: string): string {
  const u = new URL(url)
  u.searchParams.set('via', via)
  return u.toString()
}

function countShare(storeId: string, channel: string) {
  void fetch(`/api/stores/${encodeURIComponent(storeId)}/share`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ channel }),
    keepalive: true,
  }).catch(() => {})
}

export function ShareButtons({ storeId, url, title }: { storeId: string; url: string; title: string }) {
  const [copied, setCopied] = useState(false)
  const whatsapp = `https://wa.me/?text=${encodeURIComponent(`${title}: ${withVia(url, 'whatsapp')}`)}`

  const shareOther = async () => {
    const link = withVia(url, 'other')
    if (navigator.share) {
      try {
        await navigator.share({ title, url: link })
        countShare(storeId, 'other')
      } catch {
        // Cancelled.
      }
      return
    }
    try {
      await navigator.clipboard.writeText(url)
      countShare(storeId, 'copy')
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    } catch {
      window.prompt('Copy this link', url)
    }
  }

  return (
    <div className={styles.share}>
      <a
        className={`${styles.shareButton} ${styles.whatsapp}`}
        href={whatsapp}
        target="_blank"
        rel="noopener noreferrer"
        onClick={() => countShare(storeId, 'whatsapp')}
      >
        WhatsApp
      </a>
      <button type="button" className={styles.shareButton} onClick={shareOther}>
        {copied ? 'Link copied ✓' : 'Share'}
      </button>
    </div>
  )
}

/** Sharing as a small icon button, for the store's header: the share sheet,
 *  or the link copied where there isn't one. Sharing is the owner's job
 *  more than the shopper's, so it stays out of the way (STORES_UI_REVIEW.md
 *  H4 - the big green WhatsApp button read as "chat with the seller"). */
export function ShareIcon({ storeId, url, title }: { storeId: string; url: string; title: string }) {
  const [copied, setCopied] = useState(false)
  const share = async () => {
    const link = withVia(url, 'other')
    if (navigator.share) {
      try {
        await navigator.share({ title, url: link })
        countShare(storeId, 'other')
      } catch {
        // Cancelled.
      }
      return
    }
    try {
      await navigator.clipboard.writeText(url)
      countShare(storeId, 'copy')
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    } catch {
      window.prompt('Copy this link', url)
    }
  }
  return (
    <button type="button" className={shop.iconButton} onClick={share} aria-label={copied ? 'Link copied' : `Share ${title}`}>
      <Icon name={copied ? 'check' : 'share'} />
      {copied && <span className={shop.copiedTip}>Link copied</span>}
    </button>
  )
}
