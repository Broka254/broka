'use client'

// The signed-in buyer's orders from every store, newest change first, with
// the ones waiting on them marked. Works the same on a phone, a tablet and
// a computer; nothing here needs the app. Each order names its store, so a
// list with several stores' orders in it never reads as one store's.
import Link from 'next/link'
import { useEffect, useState } from 'react'

import { formatMinor, formatWhen, orderPath, orderTone, type OrderSummary } from '@/lib/orders'
import { refreshSession, signOut, useSession } from '@/lib/session-client'
import { webFetch } from '@/lib/web-api'

import account from './account.module.css'
import { EmptyState } from './EmptyState'
import { Icon } from './Icon'
import { ContinueShopping } from './LastStore'
import { OrderStatusBadge } from './OrderStatusBadge'
import styles from './orders.module.css'
import { SignInPanel } from './SignInPanel'
import { StoreAvatar } from './StoreAvatar'

type Scope = 'open' | 'closed' | 'all'

const SCOPES: ReadonlyArray<{ key: Scope; label: string }> = [
  { key: 'open', label: 'In progress' },
  { key: 'closed', label: 'Finished' },
  { key: 'all', label: 'All' },
]

export function OrdersList() {
  const session = useSession()
  const [scope, setScope] = useState<Scope>('open')
  // What was read, and for which tab: a list is only shown under the tab it
  // belongs to, never the previous tab's while the next one loads.
  const [result, setResult] = useState<{ scope: Scope; items: OrderSummary[]; total: number } | null>(null)
  const [error, setError] = useState<string | null>(null)
  // Bumped by "Try again".
  const [reads, setReads] = useState(0)

  useEffect(() => {
    if (session.status !== 'signed_in') return
    let live = true
    const read = async () => {
      const r = await webFetch<{ items: OrderSummary[]; total: number }>(`/api/stores/orders?scope=${scope}`)
      if (!live) return
      if (r.ok) {
        setError(null)
        setResult({ scope, items: r.data.items, total: r.data.total })
      } else if (r.status === 401) {
        void refreshSession()
      } else {
        setError(r.error.message)
      }
    }
    void read()
    return () => {
      live = false
    }
  }, [session.status, scope, reads])

  const orders = result && result.scope === scope ? result.items : null
  const total = result?.total ?? 0

  if (session.status === 'loading') return <p className={styles.muted}>Loading…</p>
  if (session.status === 'signed_out') {
    return <SignInPanel title="Sign in to see your orders" lead="Use the phone number you ordered with. We'll text you a code." />
  }

  return (
    <section className={styles.ordersPage} aria-labelledby="orders-title">
      <header className={account.pageHead}>
        <div>
          <h1 id="orders-title">Your orders</h1>
          <p>Orders you sent stores on BROKA, from every store.</p>
        </div>
        <p className={styles.muted}>
          Signed in as {session.user.name ?? session.user.phone}.{' '}
          <button type="button" className={styles.linkish} onClick={() => void signOut()}>
            Sign out
          </button>
        </p>
      </header>
      <div className={styles.tabs} role="tablist" aria-label="Which orders">
        {SCOPES.map((s) => (
          <button
            key={s.key}
            type="button"
            role="tab"
            aria-selected={scope === s.key}
            className={styles.tab}
            onClick={() => {
              setError(null)
              setScope(s.key)
            }}
          >
            {s.label}
          </button>
        ))}
      </div>
      {error && (
        <p className={styles.error} role="alert">
          {error}{' '}
          <button
            type="button"
            className={styles.linkish}
            onClick={() => {
              setError(null)
              setReads((n) => n + 1)
            }}
          >
            Try again
          </button>
        </p>
      )}
      {!orders && !error && (
        <div className={styles.orderList} aria-busy="true">
          <span className="visually-hidden">Loading your orders…</span>
          {[0, 1, 2].map((i) => (
            <span key={i} className={`skeleton ${styles.orderPlaceholder}`} />
          ))}
        </div>
      )}
      {orders && orders.length === 0 && (
        <EmptyState
          icon="receipt"
          title={scope === 'open' ? 'Nothing in progress.' : 'No orders here yet.'}
          actions={<ContinueShopping className="button button--ghost" />}
        >
          <p>Orders you send a store from its BROKA page appear here.</p>
        </EmptyState>
      )}
      {orders && orders.length > 0 && (
        <ul className={styles.orderList}>
          {orders.map((o) => (
            <li key={o.id}>
              <Link href={orderPath(o.id)} className={`${styles.orderCard} ${o.needs_action ? styles.needsAction : ''}`}>
                <StoreAvatar name={o.store.name ?? 'Store'} logo={null} size={44} />
                <span className={styles.orderCardBody}>
                  <span className={styles.orderCardTop}>
                    <strong>{o.store.name}</strong>
                    <span className={styles.orderCardTotal}>{formatMinor(o.total_minor, o.currency)}</span>
                  </span>
                  <span className={styles.orderCardStatus}>
                    <OrderStatusBadge tone={orderTone(o.status, o.needs_action)}>{o.status_label}</OrderStatusBadge>
                    {o.needs_action && <small className={styles.changed}>Waiting for you</small>}
                  </span>
                  <small className={styles.hint}>
                    {o.reference} · {o.first_item}
                    {o.item_count > 1 ? ` and ${o.item_count - 1} more` : ''} · {formatWhen(o.updated_at)}
                  </small>
                </span>
                <Icon name="chevron" size={18} className={styles.orderCardGo} />
              </Link>
            </li>
          ))}
        </ul>
      )}
      {orders && total > orders.length && <p className={styles.hint}>Showing the latest {orders.length} of {total}.</p>}
    </section>
  )
}
