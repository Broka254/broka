'use client'

// The signed-in buyer's orders from every store, newest change first, with
// the ones waiting on them marked. Works the same on a phone, a tablet and
// a computer; nothing here needs the app.
import Link from 'next/link'
import { useEffect, useState } from 'react'

import { formatMinor, formatWhen, orderPath, type OrderSummary } from '@/lib/orders'
import { refreshSession, signOut, useSession } from '@/lib/session-client'
import { webFetch } from '@/lib/web-api'

import styles from './orders.module.css'
import { SignInPanel } from './SignInPanel'

type Scope = 'open' | 'closed' | 'all'

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
    <section className={styles.orderPage} aria-labelledby="orders-title">
      <header className={styles.orderHead}>
        <h1 id="orders-title">Your orders</h1>
        <p className={styles.muted}>
          Signed in as {session.user.name ?? session.user.phone}.{' '}
          <button type="button" className={styles.linkish} onClick={() => void signOut()}>
            Sign out
          </button>
        </p>
      </header>
      <div className={styles.actions} role="tablist" aria-label="Which orders">
        {(['open', 'closed', 'all'] as const).map((s) => (
          <button
            key={s}
            type="button"
            role="tab"
            aria-selected={scope === s}
            className={scope === s ? styles.primary : styles.secondary}
            onClick={() => {
              setError(null)
              setScope(s)
            }}
          >
            {s === 'open' ? 'In progress' : s === 'closed' ? 'Finished' : 'All'}
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
      {!orders && !error && <p className={styles.muted}>Loading…</p>}
      {orders && orders.length === 0 && (
        <p className={styles.muted}>
          {scope === 'open' ? 'Nothing in progress.' : 'No orders here yet.'} Orders you send a store from its BROKA page
          appear here.
        </p>
      )}
      {orders && orders.length > 0 && (
        <ul className={styles.orderList}>
          {orders.map((o) => (
            <li key={o.id}>
              <Link href={orderPath(o.id)} className={`${styles.orderCard} ${o.needs_action ? styles.needsAction : ''}`}>
                <span className={styles.orderCardTop}>
                  <strong>{o.store.name}</strong>
                  <span>{formatMinor(o.total_minor, o.currency)}</span>
                </span>
                <span>{o.status_label}</span>
                <small className={styles.hint}>
                  {o.reference} · {o.first_item}
                  {o.item_count > 1 ? ` and ${o.item_count - 1} more` : ''} · {formatWhen(o.updated_at)}
                </small>
                {o.needs_action && <small className={styles.changed}>Waiting for you</small>}
              </Link>
            </li>
          ))}
        </ul>
      )}
      {orders && total > orders.length && <p className={styles.hint}>Showing the latest {orders.length} of {total}.</p>}
    </section>
  )
}
