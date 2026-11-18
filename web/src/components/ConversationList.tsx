'use client'

// The buyer's conversations with stores, as rows: with whom, about what,
// the newest line and when (lib/conversations.ts). On a store's messages
// page it lists that store's conversations - and the one open on the page,
// before its first message - with the way to every other store's; on the
// account's Messages page, every store's. Each row links to the
// conversation's own page, so a conversation keeps one address and always
// opens inside its own store's pages.
import Link from 'next/link'
import { useEffect, useState } from 'react'

import type { Conversation, ConversationList as Listed } from '@/lib/conversations'
import { accountMessagesPath } from '@/lib/links'
import { listTime } from '@/lib/messages'
import { refreshSession, useSession } from '@/lib/session-client'
import { webFetch } from '@/lib/web-api'

import { EmptyState } from './EmptyState'
import { Icon } from './Icon'
import styles from './messaging.module.css'
import { StoreAvatar } from './StoreAvatar'

type Read = { ok: true; data: Listed } | { ok: false; message: string }

function preview(c: Conversation, isDraft: boolean): string {
  if (isDraft) return 'New conversation'
  if (!c.last.text) return 'Open the conversation'
  return c.last.from === 'buyer' ? `You: ${c.last.text}` : c.last.text
}

export function ConversationList({
  variant,
  store,
  activeKey,
  draft,
  version = 0,
}: {
  variant: 'store' | 'inbox'
  /** The store page's own store: the list is its conversations. */
  store?: { id: string; name: string }
  /** The conversation open on the page. */
  activeKey?: string
  /** That conversation, as the page knows it - shown even before it has a message. */
  draft?: Conversation
  /** Bumped by the page to read the list again: a message was sent or came in. */
  version?: number
}) {
  const session = useSession()
  const userId = session.status === 'signed_in' ? session.user.id : null
  const [read, setRead] = useState<Read | null>(null)
  const [retries, setRetries] = useState(0)

  useEffect(() => {
    if (!userId) return
    let live = true
    const load = async () => {
      const r = await webFetch<Listed>(`/api/stores/conversations?user=${encodeURIComponent(userId)}`)
      if (!live) return
      if (r.ok) setRead({ ok: true, data: r.data })
      // 403: the inbox is another account's - this tab's session changed
      // in another one. Ask who is signed in now.
      else if (r.status === 401 || r.status === 403) void refreshSession()
      else setRead({ ok: false, message: r.error.message })
    }
    void load()
    // The account's list has no conversation open beside it to notice a
    // reply: it reads again when the buyer comes back to the tab.
    const onVisible = () => {
      if (document.visibilityState === 'visible') void load()
    }
    if (variant === 'inbox') document.addEventListener('visibilitychange', onVisible)
    return () => {
      live = false
      document.removeEventListener('visibilitychange', onVisible)
    }
  }, [userId, variant, version, retries])

  if (session.status !== 'signed_in') return null

  if (!read) {
    return (
      <div className={styles.rows} aria-busy="true">
        <span className="visually-hidden">Loading your conversations…</span>
        {[0, 1, 2].map((i) => (
          <div key={i} className={styles.rowPlaceholder}>
            <span className={`skeleton ${styles.rowPlaceholderAvatar}`} />
            <span className={styles.rowPlaceholderLines}>
              <span className="skeleton" />
              <span className="skeleton" />
            </span>
          </div>
        ))}
      </div>
    )
  }

  if (!read.ok) {
    return (
      <div className={styles.listError} role="alert">
        <p>{read.message}</p>
        <button type="button" className={styles.linkButton} onClick={() => setRetries((n) => n + 1)}>
          Try again
        </button>
      </div>
    )
  }

  const all = read.data.conversations
  const mine = store ? all.filter((c) => c.store.id === store.id) : all
  const rows = draft && !mine.some((c) => c.key === draft.key) ? [draft, ...mine] : mine
  const elsewhere = store ? all.length - mine.length : 0

  return (
    <>
      {rows.length === 0 ? (
        variant === 'inbox' ? (
          <EmptyState icon="chat" title="No conversations yet" testId="no-conversations">
            <p>
              Ask a store about a product, delivery or anything else from its page on BROKA, and the conversation shows
              here.
            </p>
          </EmptyState>
        ) : (
          <p className={styles.listNote}>No conversations with {store?.name} yet.</p>
        )
      ) : (
        <ul className={styles.rows} aria-label={store ? `Conversations with ${store.name}` : 'Your conversations'}>
          {rows.map((c) => {
            // Only the page's own copy of the open conversation is a draft:
            // once the inbox has it, the inbox's row (with its last line) wins.
            const isDraft = c === draft
            const active = c.key === activeKey
            const title = variant === 'inbox' ? c.store.name : (c.product?.name ?? 'Questions for the store')
            const sub = variant === 'inbox' ? (c.product ? `About ${c.product.name}` : 'Store conversation') : null
            const when = listTime(c.last.at)
            return (
              <li key={c.key}>
                <Link
                  href={c.href}
                  prefetch={false}
                  className={styles.row}
                  aria-current={active ? 'page' : undefined}
                  data-testid="conversation"
                >
                  <span className={styles.rowMedia}>
                    {c.product?.image ? (
                      // eslint-disable-next-line @next/next/no-img-element
                      <img src={c.product.image} alt="" loading="lazy" decoding="async" className={styles.rowImage} />
                    ) : (
                      <StoreAvatar name={c.store.name} logo={c.store.logo} size={44} />
                    )}
                  </span>
                  <span className={styles.rowBody}>
                    <span className={styles.rowTop}>
                      <span className={styles.rowTitle}>{title}</span>
                      {when && !isDraft && (
                        <time className={styles.rowTime} dateTime={c.last.at ?? undefined}>
                          {when}
                        </time>
                      )}
                    </span>
                    {sub && <span className={styles.rowSub}>{sub}</span>}
                    <span className={`${styles.rowPreview} ${c.last.from === 'seller' ? styles.rowPreviewTheirs : ''}`}>
                      {preview(c, isDraft)}
                    </span>
                  </span>
                </Link>
              </li>
            )
          })}
        </ul>
      )}
      {read.data.partial && (
        <p className={styles.listNote} role="status">
          Some conversations couldn&apos;t be loaded just now.{' '}
          <button type="button" className={styles.linkButton} onClick={() => setRetries((n) => n + 1)}>
            Try again
          </button>
        </p>
      )}
      {variant === 'store' && (
        <Link href={accountMessagesPath} className={styles.allLink}>
          <Icon name="chat" size={16} />
          <span>
            All your conversations
            {elsewhere > 0 && <small> · {elsewhere} with other stores</small>}
          </span>
          <Icon name="chevron" size={15} />
        </Link>
      )}
    </>
  )
}
