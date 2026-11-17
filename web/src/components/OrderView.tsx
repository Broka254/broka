'use client'

// One order, as its buyer follows it on the web: where it is, what the store
// answered, what to do next, how the buyer is paying, and everything that
// happened. Every button is one the API says the order allows now
// (allowed_actions); the API decides again when it is pressed.
//
// Payment is the buyer's arrangement with the store - directly, or through
// an independent escrow provider the buyer opens on its own website. BROKA
// records what the buyer and the store report and labels it that way; it
// never receives, holds or checks the money, and this page never says it did.
import Link from 'next/link'
import { useEffect, useRef, useState } from 'react'

import { type EscrowDirectory, isOfficialUrl, UNAVAILABLE } from '@/lib/escrow-providers'
import {
  BUYER_ACTION_LABELS,
  BUYER_REPORT_BUTTONS,
  formatMinor,
  formatWhen,
  type Order,
  type OrderItem,
  ordersPath,
  UNSUCCESSFUL,
} from '@/lib/orders'
import { storeMessagesPath, storePath } from '@/lib/links'
import { refreshSession, useSession } from '@/lib/session-client'
import { webFetch } from '@/lib/web-api'

import styles from './orders.module.css'
import { SignInPanel } from './SignInPanel'

const POLL_MS = 30_000

const YES = {
  confirm: 'Yes, confirm the order',
  reject_proposal: 'Yes, reject the changes',
  cancel: 'Yes, cancel the order',
  confirm_received: 'Yes, I have it',
} as const

type Confirming = 'confirm' | 'reject_proposal' | 'cancel' | 'confirm_received' | null

function statusClass(order: Order): string {
  if (order.status === 'completed') return `${styles.status} ${styles.statusDone}`
  if (UNSUCCESSFUL.includes(order.status)) return `${styles.status} ${styles.statusEnded}`
  if (order.allowed_actions.some((a) => a === 'confirm' || a === 'confirm_received')) {
    return `${styles.status} ${styles.statusYourTurn}`
  }
  return styles.status ?? ''
}

function ItemRow({ item, currency }: { item: OrderItem; currency: string }) {
  const priceChanged = item.proposed_unit_price_minor != null && item.proposed_unit_price_minor !== item.requested_unit_price_minor
  const qtyChanged = item.proposed_quantity != null && item.proposed_quantity !== item.requested_quantity
  return (
    <li className={styles.item}>
      {item.image ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img className={styles.thumb} src={item.image.thumb} alt="" loading="lazy" />
      ) : (
        <span className={styles.thumb} aria-hidden="true" />
      )}
      <div>
        <p className={styles.itemName}>{item.name}</p>
        {item.removed ? (
          <p className={`${styles.itemMeta} ${styles.changed}`}>The store can&apos;t supply this one.</p>
        ) : (
          <p className={styles.itemMeta}>
            {qtyChanged ? (
              <>
                <span className={styles.was}>
                  <span className="visually-hidden">You asked for </span>
                  {item.requested_quantity}
                </span>{' '}
                <span className={styles.changed}>
                  <span className="visually-hidden">the store offers </span>
                  {item.quantity}
                </span>
              </>
            ) : (
              item.quantity
            )}{' '}
            ×{' '}
            {priceChanged ? (
              <>
                <span className={styles.was}>
                  <span className="visually-hidden">listed at </span>
                  {formatMinor(item.requested_unit_price_minor, currency)}
                </span>{' '}
                <span className={styles.changed}>
                  <span className="visually-hidden">the store charges </span>
                  {formatMinor(item.unit_price_minor, currency)}
                </span>
              </>
            ) : (
              formatMinor(item.unit_price_minor, currency)
            )}
            {item.price_unit ? ` / ${item.price_unit}` : ''}
          </p>
        )}
      </div>
      <strong>{formatMinor(item.line_total_minor, currency)}</strong>
    </li>
  )
}

function deadline(order: Order): string | null {
  if (!order.expires_at) return null
  const when = formatWhen(order.expires_at)
  if (order.expiry_stage === 'seller_response') return `The store has until ${when} to reply, or the request lapses.`
  if (order.expiry_stage === 'buyer_confirmation') {
    return `Confirm by ${when}. After that the store's offer lapses and anything it set aside for you is released.`
  }
  return null
}

function eventDetail(e: Order['events'][number]): string | null {
  const d = e.detail ?? {}
  if (typeof d.reason === 'string') return d.reason
  if (typeof d.note === 'string') return d.note
  if (Array.isArray(d.changes) && d.changes.length) {
    return (d.changes as Array<Record<string, unknown>>)
      .map((c) => `${String(c.item)}: ${String(c.from_quantity)} → ${String(c.to_quantity)}`)
      .join(' · ')
  }
  if (typeof d.label === 'string') return `${d.label} (reported, not verified by BROKA)`
  return null
}

export function OrderView({ orderId, escrow = UNAVAILABLE }: { orderId: string; escrow?: EscrowDirectory }) {
  const session = useSession()
  const [order, setOrder] = useState<Order | null>(null)
  const [loadError, setLoadError] = useState<{ status: number; message: string } | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [confirming, setConfirming] = useState<Confirming>(null)
  const [reason, setReason] = useState('')
  const [problem, setProblem] = useState('')
  const [showProblem, setShowProblem] = useState(false)
  const [arrangement, setArrangement] = useState<'direct_to_seller' | 'independent_escrow'>('direct_to_seller')
  const [providerId, setProviderId] = useState('')
  const [reference, setReference] = useState('')
  const seeded = useRef(false)
  // Bumped to read the order again: by the poll below, and after an action
  // the order did not allow any more.
  const [reads, setReads] = useState(0)

  // Reads the order once signed in, and again each time `reads` changes.
  useEffect(() => {
    if (session.status !== 'signed_in') return
    let live = true
    const read = async () => {
      const r = await webFetch<Order>(`/api/stores/orders/${encodeURIComponent(orderId)}`)
      if (!live) return
      if (r.ok) {
        setOrder(r.data)
        setLoadError(null)
        // The payment choice starts as the order's own - once, so a refresh
        // while the buyer is choosing doesn't undo their choice.
        if (!seeded.current) {
          seeded.current = true
          if (r.data.payment.arrangement) setArrangement(r.data.payment.arrangement)
          if (r.data.payment.provider?.id) setProviderId(r.data.payment.provider.id)
        }
      } else if (r.status === 401) {
        // The session ended since the page loaded: show the sign-in step,
        // and read the order again once the buyer is back.
        void refreshSession()
      } else {
        setLoadError({ status: r.status, message: r.error.message })
      }
    }
    void read()
    return () => {
      live = false
    }
  }, [session.status, orderId, reads])

  // While the order is open, the store's answer appears without a reload.
  const open = order?.open === true
  useEffect(() => {
    if (!open) return
    const t = setInterval(() => {
      if (document.visibilityState === 'visible') setReads((n) => n + 1)
    }, POLL_MS)
    return () => clearInterval(t)
  }, [open])

  if (session.status === 'loading') return <p className={styles.muted}>Loading your order…</p>
  if (session.status === 'signed_out') {
    return <SignInPanel title="Sign in to see this order" lead="Use the phone number you ordered with. We'll text you a code." />
  }
  if (loadError) {
    return (
      <div className={styles.panel}>
        <p className={styles.error} role="alert">
          {loadError.status === 404 ? "We couldn't find that order on your account." : loadError.message}
        </p>
        <Link href={ordersPath} className={styles.linkish}>
          See your orders
        </Link>
      </div>
    )
  }
  if (!order) return <p className={styles.muted}>Loading your order…</p>

  const act = async (action: string, body: Record<string, unknown> = {}) => {
    if (busy) return
    setBusy(true)
    setError(null)
    const r = await webFetch<Order>(`/api/stores/orders/${encodeURIComponent(order.id)}/${action}`, {
      method: 'POST',
      body,
    })
    setBusy(false)
    setConfirming(null)
    if (r.ok) {
      setOrder(r.data)
      setReason('')
      setProblem('')
      setShowProblem(false)
      setReference('')
    } else {
      setError(r.error.message)
      if (r.status === 401) void refreshSession()
      // The order may have moved on (the store answered, the offer lapsed).
      setReads((n) => n + 1)
    }
  }

  const can = (a: string) => order.allowed_actions.includes(a)
  const total = order.totals.display_total_minor
  const payment = order.payment
  const providers = escrow.providers
  const chosenProvider = providers.find((p) => p.id === providerId)
  const orderProviderUrl =
    payment.provider?.url && payment.provider.domain && isOfficialUrl(payment.provider.url, payment.provider.domain)
      ? payment.provider.url
      : null
  const buyerReports = payment.allowed_reports.filter((k) => k in BUYER_REPORT_BUTTONS)
  const ended = UNSUCCESSFUL.includes(order.status)

  const consequence: Record<Exclude<Confirming, null>, string> = {
    confirm: `You agree to buy what is listed here for ${formatMinor(total, order.currency)}${
      order.fulfilment.method === 'delivery' ? ', delivered' : ', collected from the store'
    }. The store then prepares it. Payment is between you and the store - BROKA doesn't take it.`,
    reject_proposal:
      "The store's changes are turned down and your request goes back to it as you sent it. Anything it set aside is released.",
    cancel: "The order ends and can't be reopened. Anything the store set aside for you is released.",
    confirm_received:
      'Confirm only once you have everything and it is as agreed. This completes the order and tells the store it is done.',
  }

  return (
    <article className={styles.orderPage} data-testid="order-view">
      <header className={styles.orderHead}>
        <p className={styles.muted}>
          Order {order.reference} ·{' '}
          {order.store.slug ? <Link href={storePath(order.store.slug)}>{order.store.name}</Link> : order.store.name}
        </p>
        <h1>{order.status_label}</h1>
        <span className={statusClass(order)} data-testid="order-status">
          {order.status.replace(/_/g, ' ')}
        </span>
        {deadline(order) && <p className={styles.notice}>{deadline(order)}</p>}
      </header>

      {order.status === 'seller_proposed_changes' && (
        <p className={styles.warning} role="status">
          The store changed your order. Check every line below - nothing goes ahead unless you confirm the new details.
        </p>
      )}
      {order.seller_note && (
        <p className={styles.notice}>
          <strong>From {order.store.name}:</strong> {order.seller_note}
        </p>
      )}
      {order.decline_reason && <p className={styles.error}>Declined: {order.decline_reason}</p>}
      {order.cancel_reason && (
        <p className={styles.error}>
          Cancelled by {order.cancelled_by === 'buyer' ? 'you' : 'the store'}: {order.cancel_reason}
        </p>
      )}

      <section className={styles.panel} aria-labelledby="items-title">
        <h2 id="items-title" className={styles.panelTitle}>
          What you ordered
        </h2>
        <ul className={styles.items}>
          {order.items.map((i) => (
            <ItemRow key={i.id} item={i} currency={order.currency} />
          ))}
        </ul>
        <dl className={styles.summaryRows}>
          <div>
            <dt>{order.totals.seller_subtotal_minor != null ? "Store's subtotal" : 'Subtotal at listed prices'}</dt>
            <dd>{formatMinor(order.totals.seller_subtotal_minor ?? order.totals.requested_subtotal_minor, order.currency)}</dd>
          </div>
          <div>
            <dt>Delivery</dt>
            <dd>
              {order.fulfilment.method === 'collection'
                ? 'Collect from the store'
                : order.totals.delivery_fee_minor != null
                  ? formatMinor(order.totals.delivery_fee_minor, order.currency)
                  : order.totals.total_minor != null
                    ? 'No charge stated'
                    : 'The store will confirm'}
            </dd>
          </div>
          <div className={styles.totalRow}>
            <dt>{order.totals.final ? 'Agreed total' : order.totals.total_minor != null ? "Store's total" : 'Estimated total'}</dt>
            <dd data-testid="order-total">{formatMinor(total, order.currency)}</dd>
          </div>
        </dl>
        {!order.totals.final && !ended && (
          <p className={styles.hint}>
            {order.totals.total_minor == null
              ? 'The store confirms availability, quantities, prices and any delivery charge first.'
              : 'Not final until you confirm.'}
          </p>
        )}
      </section>

      <section className={styles.panel} aria-labelledby="handover-title">
        <h2 id="handover-title" className={styles.panelTitle}>
          {order.fulfilment.method === 'delivery' ? 'Delivery' : 'Collection'}
        </h2>
        {order.fulfilment.method !== order.fulfilment.requested_method && (
          <p className={styles.changed}>
            You asked for {order.fulfilment.requested_method}; the store offers {order.fulfilment.method}.
          </p>
        )}
        {order.fulfilment.address && <p className={styles.muted}>To: {order.fulfilment.address}</p>}
        {order.fulfilment.note && <p className={styles.muted}>Store: {order.fulfilment.note}</p>}
        {order.fulfilment.dispatch_note && <p className={styles.muted}>Dispatch: {order.fulfilment.dispatch_note}</p>}
        {order.buyer_note && <p className={styles.muted}>Your note: {order.buyer_note}</p>}
      </section>

      {(can('confirm') || can('reject_proposal') || can('cancel') || can('confirm_received') || can('report_problem')) && (
        <section className={styles.panel} aria-labelledby="next-title">
          <h2 id="next-title" className={styles.panelTitle}>
            What next
          </h2>
          {confirming ? (
            <div className={styles.field} role="group" aria-label="Confirm your choice">
              <p className={styles.notice}>{consequence[confirming]}</p>
              {(confirming === 'cancel' || confirming === 'reject_proposal') && (
                <textarea
                  className={styles.textarea}
                  aria-label="Tell the store why (optional)"
                  placeholder="Tell the store why (optional)"
                  maxLength={300}
                  value={reason}
                  onChange={(e) => setReason(e.target.value)}
                />
              )}
              <div className={styles.actions}>
                <button
                  type="button"
                  className={confirming === 'cancel' ? styles.danger : styles.primary}
                  disabled={busy}
                  onClick={() =>
                    confirming === 'confirm'
                      ? act('confirm', { revision: order.revision })
                      : confirming === 'reject_proposal'
                        ? act('reject-proposal', { note: reason })
                        : confirming === 'cancel'
                          ? act('cancel', { reason })
                          : act('received')
                  }
                >
                  {busy ? 'Working…' : YES[confirming]}
                </button>
                <button type="button" className={styles.secondary} onClick={() => setConfirming(null)} disabled={busy}>
                  Not now
                </button>
              </div>
            </div>
          ) : (
            <div className={styles.actions}>
              {can('confirm') && (
                <button type="button" className={styles.primary} onClick={() => setConfirming('confirm')}>
                  {BUYER_ACTION_LABELS.confirm} - {formatMinor(total, order.currency)}
                </button>
              )}
              {can('confirm_received') && (
                <button type="button" className={styles.primary} onClick={() => setConfirming('confirm_received')}>
                  {BUYER_ACTION_LABELS.confirm_received}
                </button>
              )}
              {can('reject_proposal') && (
                <button type="button" className={styles.secondary} onClick={() => setConfirming('reject_proposal')}>
                  {BUYER_ACTION_LABELS.reject_proposal}
                </button>
              )}
              {can('report_problem') && (
                <button type="button" className={styles.secondary} onClick={() => setShowProblem((v) => !v)}>
                  {BUYER_ACTION_LABELS.report_problem}
                </button>
              )}
              {can('cancel') && (
                <button type="button" className={styles.danger} onClick={() => setConfirming('cancel')}>
                  {BUYER_ACTION_LABELS.cancel}
                </button>
              )}
            </div>
          )}
          {showProblem && !confirming && (
            <div className={styles.field}>
              <label htmlFor="problem-note">What went wrong?</label>
              <textarea
                id="problem-note"
                className={styles.textarea}
                maxLength={500}
                value={problem}
                onChange={(e) => setProblem(e.target.value)}
              />
              <button
                type="button"
                className={styles.secondary}
                disabled={busy || problem.trim().length < 5}
                onClick={() => act('problem', { note: problem })}
              >
                Send to the store
              </button>
            </div>
          )}
        </section>
      )}
      {order.problem && (
        <p className={styles.warning}>
          You reported a problem {formatWhen(order.problem.reported_at)}: {order.problem.note}
        </p>
      )}
      {error && (
        <p className={styles.error} role="alert" data-testid="order-error">
          {error}
        </p>
      )}

      {!ended && (
        <section className={styles.panel} aria-labelledby="payment-title" data-testid="payment">
          <h2 id="payment-title" className={styles.panelTitle}>
            Paying
          </h2>
          <p className={styles.notice}>{payment.notice}</p>
          {payment.arrangement && (
            <p>
              <strong>{payment.arrangement_label}</strong>
              {payment.provider?.name ? ` - ${payment.provider.name}` : ''}
            </p>
          )}
          {payment.provider && (
            <div className={styles.provider}>
              <p className={styles.hint}>{payment.provider.notice}</p>
              {orderProviderUrl && (
                <a href={orderProviderUrl} target="_blank" rel="noopener noreferrer nofollow" className={styles.linkish}>
                  Open {payment.provider.name}&apos;s official website ({payment.provider.domain})
                </a>
              )}
            </div>
          )}
          <p data-testid="payment-summary">
            {payment.summary.label}
            {payment.summary.status_note ? ` · ${payment.summary.status_note}` : ''}
          </p>
          {payment.reports.length > 0 && (
            <ul className={styles.reportList}>
              {payment.reports.map((r) => (
                <li key={r.kind}>
                  <strong>{r.label}</strong>
                  <br />
                  <small className={styles.hint}>
                    Reported by {r.actor_role === 'buyer' ? 'you' : 'the store'} {formatWhen(r.created_at)} · not verified by
                    BROKA{r.reference ? ` · reference ${r.reference}` : ''}
                  </small>
                </li>
              ))}
            </ul>
          )}

          {payment.can_choose && (
            <div className={styles.field}>
              <span className={styles.fieldLabel}>How will you pay?</span>
              <div className={styles.choices}>
                <label className={`${styles.choice} ${arrangement === 'direct_to_seller' ? styles.choiceActive : ''}`}>
                  <input
                    type="radio"
                    name="arrangement"
                    checked={arrangement === 'direct_to_seller'}
                    onChange={() => setArrangement('direct_to_seller')}
                  />
                  <span>
                    <strong>Pay the store directly</strong>
                    <br />
                    <small className={styles.hint}>Best when you can see the item first, e.g. on collection.</small>
                  </span>
                </label>
                <label className={`${styles.choice} ${arrangement === 'independent_escrow' ? styles.choiceActive : ''}`}>
                  <input
                    type="radio"
                    name="arrangement"
                    checked={arrangement === 'independent_escrow'}
                    onChange={() => setArrangement('independent_escrow')}
                  />
                  <span>
                    <strong>Use an independent escrow service</strong>
                    <br />
                    <small className={styles.hint}>A separate company, with its own fees and rules - not BROKA.</small>
                  </span>
                </label>
              </div>
              {arrangement === 'independent_escrow' && (
                <div className={styles.providers}>
                  {providers.length === 0 && (
                    <p className={styles.warning}>
                      The list of escrow services could not be loaded just now. Try again in a minute - don&apos;t use a link
                      the store sends you instead.
                    </p>
                  )}
                  {providers.map((p) => (
                    <label key={p.id} className={`${styles.provider} ${providerId === p.id ? styles.choiceActive : ''}`}>
                      <span className={styles.check}>
                        <input type="radio" name="provider" checked={providerId === p.id} onChange={() => setProviderId(p.id)} />
                        <span>
                          <span className={styles.providerName}>{p.name}</span> <small className={styles.hint}>{p.reviewLabel}</small>
                        </span>
                      </span>
                      <small className={styles.hint}>
                        {p.feeSummary}
                        {p.summary ? ` · ${p.summary}` : ''}
                      </small>
                      {p.warning && <small className={styles.hint}>{p.warning}</small>}
                      {p.notToBeConfusedWith && <small className={styles.hint}>{p.notToBeConfusedWith}</small>}
                    </label>
                  ))}
                  <p className={styles.hint}>{escrow.disclaimer}</p>
                </div>
              )}
              <button
                type="button"
                className={styles.secondary}
                disabled={busy || (arrangement === 'independent_escrow' && !chosenProvider)}
                onClick={() =>
                  act('payment-arrangement', {
                    arrangement,
                    provider_id: arrangement === 'independent_escrow' ? providerId : undefined,
                  })
                }
              >
                {payment.arrangement ? 'Change how I pay' : 'Save how I pay'}
              </button>
            </div>
          )}

          {buyerReports.length > 0 && (
            <div className={styles.field}>
              <label htmlFor="payment-reference">Payment reference (optional)</label>
              <input
                id="payment-reference"
                className={styles.input}
                maxLength={64}
                autoComplete="off"
                value={reference}
                onChange={(e) => setReference(e.target.value)}
                placeholder="e.g. an M-Pesa or escrow transaction code"
              />
              <p className={styles.hint}>Never type your M-Pesa PIN, a password or card details here or anywhere on BROKA.</p>
              <div className={styles.actions}>
                {buyerReports.map((kind) => (
                  <button
                    key={kind}
                    type="button"
                    className={styles.secondary}
                    disabled={busy}
                    onClick={() => act('payment-reports', { kind, reference: reference.trim() || undefined })}
                  >
                    {BUYER_REPORT_BUTTONS[kind]}
                  </button>
                ))}
              </div>
              <p className={styles.hint}>This tells the store what you did. It is your report, not a confirmation from BROKA.</p>
            </div>
          )}
        </section>
      )}

      {order.store.slug && (
        <p>
          <Link href={storeMessagesPath(order.store.slug)} className={styles.linkish}>
            Message {order.store.name} about this order
          </Link>
        </p>
      )}

      <section className={styles.panel} aria-labelledby="history-title">
        <h2 id="history-title" className={styles.panelTitle}>
          History
        </h2>
        <ol className={styles.timeline}>
          {order.events.map((e) => (
            <li key={e.id}>
              <strong>{e.label}</strong>
              {eventDetail(e) && <span className={styles.muted}>{eventDetail(e)}</span>}
              <time dateTime={e.created_at ?? undefined}>{formatWhen(e.created_at)}</time>
            </li>
          ))}
        </ol>
      </section>
      <p>
        <Link href={ordersPath} className={styles.linkish}>
          All your orders
        </Link>
      </p>
    </article>
  )
}
