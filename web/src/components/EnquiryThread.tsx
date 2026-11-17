'use client'

// Asking a store a question from its website - about the shop, or about one
// product - and reading its replies, with no app. The same conversation the
// app shows: the store answers it from BROKA, and both sides see it there.
// Sign-in is an SMS code; there is no anonymous messaging.
import { type FormEvent, useCallback, useEffect, useRef, useState } from 'react'

import { formatWhen } from '@/lib/orders'
import { useSession } from '@/lib/session-client'
import { newKey, webFetch } from '@/lib/web-api'

import styles from './orders.module.css'
import { SignInPanel } from './SignInPanel'

interface Message {
  id: string | null
  role: 'buyer' | 'seller'
  content: string
  kind: string
  created_at: string | null
}

const POLL_MS = 20_000

export function EnquiryThread({
  storeId,
  storeName,
  listingId,
  productName,
}: {
  storeId: string
  storeName: string
  listingId?: string
  productName?: string
}) {
  const session = useSession()
  const [messages, setMessages] = useState<Message[] | null>(null)
  const [text, setText] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  // One id per message being written: a retry after a dropped connection
  // is the same message, not a second one (the chat engine dedupes on it).
  const pendingId = useRef<string>(newKey())
  const query = listingId ? `?listing=${encodeURIComponent(listingId)}` : ''

  const load = useCallback(async () => {
    const r = await webFetch<{ messages: Message[] }>(`/api/stores/${encodeURIComponent(storeId)}/enquiries${query}`)
    if (r.ok) setMessages(r.data.messages)
    else if (r.status !== 401) setError(r.error.message)
  }, [storeId, query])

  useEffect(() => {
    if (session.status === 'signed_in') void load()
  }, [session.status, load])

  useEffect(() => {
    if (session.status !== 'signed_in') return
    const t = setInterval(() => {
      if (document.visibilityState === 'visible') void load()
    }, POLL_MS)
    return () => clearInterval(t)
  }, [session.status, load])

  if (session.status === 'loading') return <p className={styles.muted}>Loading…</p>
  if (session.status === 'signed_out') {
    return (
      <SignInPanel
        title={`Sign in to message ${storeName}`}
        lead="We'll text you a code - no app needed. The store replies here and in the BROKA app."
      />
    )
  }

  const send = async (e: FormEvent) => {
    e.preventDefault()
    const content = text.trim()
    if (busy || content.length < 2) return
    setBusy(true)
    setError(null)
    const r = await webFetch(`/api/stores/${encodeURIComponent(storeId)}/enquiries`, {
      method: 'POST',
      body: { content, listing_id: listingId, client_msg_id: pendingId.current },
    })
    setBusy(false)
    if (!r.ok) return setError(r.error.message)
    pendingId.current = newKey()
    setText('')
    void load()
  }

  return (
    <section className={styles.panel} aria-labelledby="enquiry-title" data-testid="enquiry-thread">
      <h2 id="enquiry-title" className={styles.panelTitle}>
        {productName ? `Ask ${storeName} about ${productName}` : `Message ${storeName}`}
      </h2>
      {messages && messages.length === 0 && (
        <p className={styles.muted}>No messages yet. Ask about stock, delivery, sizes - the store usually answers here.</p>
      )}
      {messages && messages.length > 0 && (
        <ol className={styles.thread} aria-live="polite">
          {messages.map((m, i) => (
            <li key={m.id ?? i} className={`${styles.bubble} ${m.role === 'buyer' ? styles.mine : ''}`}>
              {m.kind === 'text' ? m.content : m.kind === 'image' ? '📷 A photo - open the BROKA app to see it.' : '🎙️ A voice note or file - open the BROKA app.'}
              <br />
              <small className={styles.hint}>
                {m.role === 'buyer' ? 'You' : storeName} · {formatWhen(m.created_at)}
              </small>
            </li>
          ))}
        </ol>
      )}
      <form onSubmit={send} className={styles.composer}>
        <textarea
          className={styles.textarea}
          aria-label="Your message"
          placeholder="Write your question"
          maxLength={2000}
          value={text}
          onChange={(e) => setText(e.target.value)}
        />
        <button type="submit" className={styles.secondary} disabled={busy || text.trim().length < 2}>
          {busy ? 'Sending…' : 'Send'}
        </button>
      </form>
      <p className={styles.hint}>
        Keep the conversation here: never pay to a number or link sent in a chat - agree the order on BROKA first.
      </p>
      {error && (
        <p className={styles.error} role="alert">
          {error}
        </p>
      )}
    </section>
  )
}
