'use client'

// Sending a store an order request from the website - on any phone, tablet
// or computer, with no app. The buyer says how they want it and how the
// store can reach them; the store then confirms availability, quantities,
// prices and delivery or collection, and the buyer confirms that before
// anything else happens. Nothing is paid here: payment is arranged with the
// store afterwards, directly or through an independent escrow service.
//
// What is sent is products, quantities and the buyer's own details - never
// a price or a total; the API reads those from the listings. One request
// key per attempt (kept in this tab), so a double tap or a retry after a
// dropped connection returns the order the first one made.
import { useRouter } from 'next/navigation'
import { type FormEvent, useEffect, useMemo, useRef, useState } from 'react'

import { type CartLine, cart } from '@/lib/cart'
import { orderPath } from '@/lib/orders'
import { useSession } from '@/lib/session-client'
import { newKey, webFetch } from '@/lib/web-api'

import styles from './orders.module.css'
import { SignInPanel } from './SignInPanel'

type Method = 'delivery' | 'collection'

interface Draft {
  method: Method
  address: string
  /** null until the buyer edits it: the field then shows the account's own number. */
  phone: string | null
  note: string
}

const EMPTY_DRAFT: Draft = { method: 'delivery', address: '', phone: null, note: '' }

const DRAFT = 'broka_checkout_'
const ATTEMPT = 'broka_order_attempt_'
const ATTRIBUTION = 'broka_attr_'
const ATTRIBUTION_DAYS = 7

function readSession<T>(key: string): T | null {
  try {
    const raw = sessionStorage.getItem(key)
    return raw ? (JSON.parse(raw) as T) : null
  } catch {
    return null
  }
}

function writeSession(key: string, value: unknown) {
  try {
    if (value === null) sessionStorage.removeItem(key)
    else sessionStorage.setItem(key, JSON.stringify(value))
  } catch {
    // Private mode: kept in this page only.
  }
}

/** The form as this tab left it (a reload, a trip back to the shop). Only
 *  fields of the right shape are taken: it is read back from storage. */
function restoreDraft(storeId: string): Draft {
  const saved = readSession<Partial<Draft>>(DRAFT + storeId)
  if (!saved || typeof saved !== 'object') return EMPTY_DRAFT
  return {
    method: saved.method === 'collection' ? 'collection' : 'delivery',
    address: typeof saved.address === 'string' ? saved.address.slice(0, 300) : '',
    phone: typeof saved.phone === 'string' ? saved.phone.slice(0, 20) : null,
    note: typeof saved.note === 'string' ? saved.note.slice(0, 500) : '',
  }
}

/** The campaign link that brought this browser to the store, if recent
 *  (VisitBeacon remembers it). */
function attribution(storeId: string): { via?: string; campaign?: string } {
  try {
    const raw = localStorage.getItem(ATTRIBUTION + storeId)
    if (!raw) return {}
    const a = JSON.parse(raw) as { via?: string; c?: string; at?: number }
    if (!a.at || Date.now() - a.at > ATTRIBUTION_DAYS * 86_400_000) return {}
    return { via: a.via, campaign: a.c }
  } catch {
    return {}
  }
}

export function WebCheckout({
  storeId,
  storeName,
  lines,
  accepting = true,
  pauseNote,
}: {
  storeId: string
  storeName: string
  lines: CartLine[]
  /** The store's own pause on new orders. */
  accepting?: boolean
  pauseNote?: string | null
}) {
  const session = useSession()
  const router = useRouter()
  // Work in progress survives a reload, a trip back to the shop and a
  // dropped connection - in this tab only. It is read here rather than in
  // an effect: the form isn't drawn until the session is known, so the
  // server's page and the browser's first render still match.
  const [draft, setDraft] = useState<Draft>(() => restoreDraft(storeId))
  const [busy, setBusy] = useState(false)
  // Set the moment a request goes out, before React has drawn the disabled
  // button: a second tap in that gap sends nothing.
  const sending = useRef(false)
  const [error, setError] = useState<{ message: string; listingId?: string } | null>(null)
  useEffect(() => {
    writeSession(DRAFT + storeId, draft)
  }, [draft, storeId])

  // The number the store can reach the buyer on: what they typed, or until
  // they type, the one on their account.
  const accountPhone = session.status === 'signed_in' ? (session.user.phone ?? '') : ''
  const phone = draft.phone ?? accountPhone

  const body = useMemo(() => ({
    items: lines.map((l) => ({ listing_id: l.id, quantity: l.qty })),
    fulfilment: draft.method,
    delivery_address: draft.method === 'delivery' ? draft.address.trim() : undefined,
    contact_phone: phone.trim() || undefined,
    note: draft.note.trim() || undefined,
    ...attribution(storeId),
  }), [lines, draft, phone, storeId])

  if (!accepting) {
    return (
      <p className={styles.warning} role="status" data-testid="orders-paused">
        {storeName} isn&apos;t taking new orders right now.{pauseNote ? ` ${pauseNote}` : ''} Your cart stays saved in this
        browser.
      </p>
    )
  }
  if (session.status === 'loading') return <p className={styles.muted}>Checking whether you&apos;re signed in…</p>
  if (session.status === 'signed_out') {
    return <SignInPanel title="Sign in to send your order" lead="We'll text you a code - no app or password needed. Your cart stays as it is." />
  }

  const set = (patch: Partial<Draft>) => setDraft((d) => ({ ...d, ...patch }))
  const needsAddress = draft.method === 'delivery' && draft.address.trim().length < 5

  const submit = async (e: FormEvent) => {
    e.preventDefault()
    if (busy || sending.current) return
    if (needsAddress) return setError({ message: 'Add a delivery address - an area and a landmark is enough.' })
    sending.current = true
    setBusy(true)
    setError(null)
    // Same request, same key: a retry can only ever return the first order.
    const fingerprint = JSON.stringify(body)
    const attempt = readSession<{ key: string; fingerprint: string }>(ATTEMPT + storeId)
    const key = attempt && attempt.fingerprint === fingerprint ? attempt.key : newKey()
    writeSession(ATTEMPT + storeId, { key, fingerprint })
    const r = await webFetch<{ id: string }>(`/api/stores/${encodeURIComponent(storeId)}/orders`, {
      method: 'POST',
      body,
      idempotencyKey: key,
    })
    if (r.ok) {
      writeSession(ATTEMPT + storeId, null)
      writeSession(DRAFT + storeId, null)
      cart.clear(storeId)
      router.push(orderPath(r.data.id))
      return
    }
    sending.current = false
    setBusy(false)
    if (r.error.code === 'IDEMPOTENCY_KEY_REUSED') writeSession(ATTEMPT + storeId, null)
    setError({
      message: r.error.message,
      listingId: typeof r.error.listing_id === 'string' ? r.error.listing_id : undefined,
    })
  }

  const problemLine = error?.listingId ? lines.find((l) => l.id === error.listingId) : undefined

  return (
    <form className={styles.panel} onSubmit={submit} aria-labelledby="checkout-title" data-testid="web-checkout" noValidate>
      <h2 id="checkout-title" className={styles.panelTitle}>
        Send your order to {storeName}
      </h2>
      <fieldset className={styles.field} style={{ border: 0, padding: 0, margin: 0 }}>
        <legend className={styles.fieldLabel}>How do you want to get it?</legend>
        <div className={styles.choices}>
          {(['delivery', 'collection'] as const).map((m) => (
            <label key={m} className={`${styles.choice} ${draft.method === m ? styles.choiceActive : ''}`}>
              <input type="radio" name="fulfilment" value={m} checked={draft.method === m} onChange={() => set({ method: m })} />
              <span>
                <strong>{m === 'delivery' ? 'Delivery' : 'Collect from the store'}</strong>
                <br />
                <small className={styles.hint}>
                  {m === 'delivery' ? 'The store confirms whether it delivers there, and any charge.' : 'The store tells you where and when.'}
                </small>
              </span>
            </label>
          ))}
        </div>
      </fieldset>
      {draft.method === 'delivery' && (
        <div className={styles.field}>
          <label htmlFor="checkout-address">Delivery address</label>
          <textarea
            id="checkout-address"
            className={styles.textarea}
            autoComplete="street-address"
            placeholder="Area, building or landmark - e.g. Kilimani, opposite Yaya Centre"
            value={draft.address}
            maxLength={300}
            onChange={(e) => set({ address: e.target.value })}
          />
        </div>
      )}
      <div className={styles.field}>
        <label htmlFor="checkout-phone">Phone the store can reach you on</label>
        <input
          id="checkout-phone"
          className={styles.input}
          type="tel"
          inputMode="tel"
          autoComplete="tel"
          value={phone}
          maxLength={20}
          onChange={(e) => set({ phone: e.target.value })}
        />
        <p className={styles.hint}>Only {storeName} sees it, and only for this order.</p>
      </div>
      <div className={styles.field}>
        <label htmlFor="checkout-note">Anything the store should know? (optional)</label>
        <textarea
          id="checkout-note"
          className={styles.textarea}
          value={draft.note}
          maxLength={500}
          placeholder="Colour, size, a good time to deliver…"
          onChange={(e) => set({ note: e.target.value })}
        />
      </div>
      <ol className={styles.muted} style={{ paddingLeft: 18, display: 'grid', gap: 4 }}>
        <li>{storeName} checks it has everything and confirms quantities, prices and delivery or collection.</li>
        <li>You review the store&apos;s final details and confirm them - or say no.</li>
        <li>
          You pay the store directly, or through an independent escrow service you choose. BROKA does not take or hold the
          payment.
        </li>
        <li>You follow the order here, on any device - no app needed.</li>
      </ol>
      {error && (
        <p className={styles.error} role="alert" data-testid="checkout-error">
          {problemLine ? `${problemLine.name}: ` : ''}
          {error.message}
        </p>
      )}
      <button type="submit" className={styles.primary} disabled={busy || lines.length === 0} data-testid="send-order">
        {busy ? 'Sending your order…' : 'Send order request'}
      </button>
      <p className={styles.hint}>Sending this doesn&apos;t pay for anything or commit you: the store answers first.</p>
    </form>
  )
}
