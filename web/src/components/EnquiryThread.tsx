'use client'

// Asking a store a question from its website - about the shop, or about one
// product - and reading its replies, with no app. The same conversation the
// app shows: the store answers it from BROKA, and both sides see it there.
// Sign-in is an SMS code; there is no anonymous messaging.
//
// A message shows the moment it is sent, marked "Sending…", until the
// thread read after it carries the stored copy - which keeps the id this
// browser gave it (client_msg_id), so the two are never drawn as two. One
// that fails stays where it was, saying why, with Retry when sending it
// again is safe: the same id goes again, and the chat engine answers a
// repeat with the message it already stored (lib/messages.ts sendFailure).
//
// The thread is read again every 20 seconds while the page is on screen,
// and at once when the buyer comes back to the tab. The view follows new
// messages only while the buyer is at the latest ones: someone reading
// further up gets a "New messages" button instead of being pulled down.
import { type ReactNode, useCallback, useEffect, useMemo, useRef, useState } from 'react'

import { MAX_MESSAGE_LENGTH, MIN_MESSAGE_LENGTH, sendFailure, type ThreadMessage } from '@/lib/messages'
import { refreshSession, useSession } from '@/lib/session-client'
import { newKey, webFetch } from '@/lib/web-api'

import { Icon } from './Icon'
import { MessageComposer } from './MessageComposer'
import { MessageHistory, type ShownMessage } from './MessageHistory'
import styles from './messaging.module.css'
import { SignInPanel } from './SignInPanel'

const POLL_MS = 20_000
/** Within this of the newest message, the view keeps following new ones. */
const NEAR_LATEST_PX = 140
/** Wider than this the thread scrolls inside its panel; narrower, the page
 *  is the chat screen and scrolls itself (messaging.module.css). */
const PANEL_LAYOUT = '(min-width: 861px)'

interface Pending {
  /** The client_msg_id it is sent with. */
  id: string
  content: string
  status: 'sending' | 'sent' | 'failed'
  /** When the buyer sent it. */
  at: string
  serverId?: string | null
  error?: string
  retryable?: boolean
}

const draftKey = (storeId: string, listingId?: string) => `broka_enquiry_draft:${storeId}:${listingId ?? 'store'}`

function readDraft(key: string): string {
  try {
    return (sessionStorage.getItem(key) ?? '').slice(0, MAX_MESSAGE_LENGTH)
  } catch {
    return ''
  }
}

/** What the buyer was writing survives a look at the product and back -
 *  in this tab only. */
function writeDraft(key: string, text: string) {
  try {
    if (text) sessionStorage.setItem(key, text)
    else sessionStorage.removeItem(key)
  } catch {
    // Private mode: kept on this page only.
  }
}

const media = (query: string) => typeof window.matchMedia === 'function' && window.matchMedia(query).matches
const inPanel = () => media(PANEL_LAYOUT)
const smoothly = (): ScrollBehavior => (media('(prefers-reduced-motion: reduce)') ? 'auto' : 'smooth')

/** A message's identity across the browser's copy and the stored one. */
const keyOf = (m: ShownMessage, i: number) => (m.client_msg_id ? `c:${m.client_msg_id}` : m.id ? `m:${m.id}` : `i:${i}`)

function sameThread(a: ThreadMessage[] | null, b: ThreadMessage[]): boolean {
  if (!a || a.length !== b.length) return false
  return a.every((m, i) => {
    const n = b[i]!
    return m.id === n.id && m.content === n.content && m.kind === n.kind && m.created_at === n.created_at
  })
}

/** The thread as read, then this browser's messages it doesn't have yet. */
function shownMessages(messages: ThreadMessage[] | null, pending: Pending[]): ShownMessage[] {
  const shown: ShownMessage[] = [...(messages ?? [])]
  const ids = new Set(shown.map((m) => m.id).filter(Boolean))
  const clientIds = new Set(shown.map((m) => m.client_msg_id).filter(Boolean))
  for (const p of pending) {
    if (clientIds.has(p.id) || (p.serverId && ids.has(p.serverId))) continue
    shown.push({
      id: null,
      role: 'buyer',
      content: p.content,
      kind: 'text',
      created_at: p.at,
      client_msg_id: p.id,
      local: { status: p.status, error: p.error, retryable: p.retryable },
    })
  }
  return shown
}

const STARTERS = {
  product: ['Is it still available?', 'How much is delivery to my area?', 'When could I get it?'],
  store: ['Do you deliver to my area?', 'When are you open?', 'Can you help me find something?'],
}

export function EnquiryThread({
  storeId,
  storeName,
  storeLogo = null,
  listingId,
  productName,
  header,
  onActivity,
}: {
  storeId: string
  storeName: string
  storeLogo?: string | null
  listingId?: string
  productName?: string
  /** The conversation's header (ConversationHeader): who, and what about. */
  header?: ReactNode
  /** The conversation moved - a message sent, or new ones read - so a list of conversations can catch up. */
  onActivity?: () => void
}) {
  const session = useSession()
  const signedIn = session.status === 'signed_in'
  const [messages, setMessages] = useState<ThreadMessage[] | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [pending, setPending] = useState<Pending[]>([])
  const draftAt = draftKey(storeId, listingId)
  const [text, setText] = useState(() => readDraft(draftAt))
  const [unseen, setUnseen] = useState(false)
  const url = `/api/stores/${encodeURIComponent(storeId)}/enquiries`
  const query = listingId ? `?listing=${encodeURIComponent(listingId)}` : ''

  const historyRef = useRef<HTMLDivElement>(null)
  const endRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLTextAreaElement>(null)
  const nearLatest = useRef(true)
  const typing = useRef(false)
  const reading = useRef(false)
  const readAgain = useRef(false)
  const lastRead = useRef(0)
  const sending = useRef(false)
  // One id per message being written: a retry after a dropped connection is
  // the same message, not a second one (the chat engine dedupes on it).
  const nextId = useRef<string>(newKey())
  const latestKey = useRef<string | null>(null)
  // How to scroll once the next newest message is drawn: straight there
  // when the thread first opens, smoothly after the buyer sends.
  const follow = useRef<ScrollBehavior | null>('auto')
  const activity = useRef(onActivity)
  useEffect(() => {
    activity.current = onActivity
  }, [onActivity])

  const isNearLatest = useCallback((): boolean => {
    const el = historyRef.current
    if (el && inPanel()) return el.scrollHeight - el.scrollTop - el.clientHeight <= NEAR_LATEST_PX
    const doc = document.documentElement
    return doc.scrollHeight - window.scrollY - window.innerHeight <= NEAR_LATEST_PX
  }, [])

  const scrollToLatest = useCallback((behavior: ScrollBehavior) => {
    const el = historyRef.current
    if (el && inPanel()) {
      if (typeof el.scrollTo === 'function') el.scrollTo({ top: el.scrollHeight, behavior })
      else el.scrollTop = el.scrollHeight
    } else {
      // The page scrolls on a phone; the end marker keeps clear of the
      // composer pinned along the bottom (scroll-margin in the CSS).
      endRef.current?.scrollIntoView?.({ block: 'end', behavior })
    }
    nearLatest.current = true
  }, [])

  // Reads the thread; a read asked for while one is under way runs after it
  // instead of beside it, so a reply is never missed and never doubled.
  const read = useCallback(async () => {
    if (reading.current) {
      readAgain.current = true
      return
    }
    reading.current = true
    try {
      do {
        readAgain.current = false
        const r = await webFetch<{ messages: ThreadMessage[] }>(`${url}${query}`)
        lastRead.current = Date.now()
        if (r.ok) {
          const next = Array.isArray(r.data.messages) ? r.data.messages : []
          setLoadError(null)
          setMessages((prev) => (sameThread(prev, next) ? prev : next))
        } else if (r.status === 401) {
          void refreshSession()
        } else {
          setLoadError(r.error.message)
        }
      } while (readAgain.current)
    } finally {
      reading.current = false
    }
  }, [url, query])

  // Reads the thread once signed in, and again while the page is on screen,
  // so the store's reply appears without a reload.
  useEffect(() => {
    if (!signedIn) return
    void read()
    const t = setInterval(() => {
      if (document.visibilityState === 'visible') void read()
    }, POLL_MS)
    const onVisible = () => {
      if (document.visibilityState === 'visible' && Date.now() - lastRead.current > 5_000) void read()
    }
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      clearInterval(t)
      document.removeEventListener('visibilitychange', onVisible)
    }
  }, [signedIn, read])

  useEffect(() => {
    writeDraft(draftAt, text)
  }, [draftAt, text])

  // Where the buyer is in the thread: following the newest, or reading back.
  useEffect(() => {
    if (!signedIn) return
    const el = historyRef.current
    const onScroll = () => {
      nearLatest.current = isNearLatest()
      if (nearLatest.current) setUnseen(false)
    }
    el?.addEventListener('scroll', onScroll, { passive: true })
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => {
      el?.removeEventListener('scroll', onScroll)
      window.removeEventListener('scroll', onScroll)
    }
  }, [signedIn, isNearLatest])

  // A phone's keyboard opening shrinks the screen: keep the newest message
  // in sight above it, if that is where the buyer was.
  useEffect(() => {
    const viewport = window.visualViewport
    if (!viewport) return
    const onResize = () => {
      if (typing.current && nearLatest.current) scrollToLatest('auto')
    }
    viewport.addEventListener('resize', onResize)
    return () => viewport.removeEventListener('resize', onResize)
  }, [scrollToLatest])

  const shown = useMemo(() => shownMessages(messages, pending), [messages, pending])
  const last = shown.at(-1)
  const lastKey = last ? keyOf(last, shown.length - 1) : null
  const lastRole = last?.role ?? null

  // A new newest message: follow it, or - reading further up - say so.
  useEffect(() => {
    if (!lastKey || lastKey === latestKey.current) return
    const first = latestKey.current === null
    latestKey.current = lastKey
    const behavior = follow.current
    follow.current = null
    if (!first && lastRole === 'seller') activity.current?.()
    if (behavior || nearLatest.current) {
      scrollToLatest(behavior ?? smoothly())
      return
    }
    // The flag follows the scroll position, which only the browser knows.
    const t = setTimeout(() => setUnseen(true), 0)
    return () => clearTimeout(t)
  }, [lastKey, lastRole, scrollToLatest])

  const deliver = useCallback(
    async (id: string, content: string) => {
      sending.current = true
      setPending((list) => list.map((p) => (p.id === id ? { ...p, status: 'sending', error: undefined } : p)))
      const r = await webFetch<{ message?: { id?: unknown } }>(url, {
        method: 'POST',
        body: { content, listing_id: listingId, client_msg_id: id },
      })
      sending.current = false
      if (r.ok) {
        const serverId = typeof r.data?.message?.id === 'string' ? r.data.message.id : null
        setPending((list) => list.map((p) => (p.id === id ? { ...p, status: 'sent', serverId } : p)))
        activity.current?.()
        void read()
        return
      }
      if (r.status === 401) {
        // Signed out meanwhile: the sign-in step shows, and the message
        // waits in the box for after it.
        setPending((list) => list.filter((p) => p.id !== id))
        setText((t) => (t.trim() ? t : content))
        void refreshSession()
        return
      }
      const failure = sendFailure(r.status, r.error)
      setPending((list) =>
        list.map((p) => (p.id === id ? { ...p, status: 'failed', error: failure.message, retryable: failure.retryable } : p)),
      )
    },
    [url, listingId, read],
  )

  const busy = pending.some((p) => p.status === 'sending')

  // A message that fails grows by its reason and its Retry, below what was
  // in view: brought into view - on a phone they were left under the box
  // pinned along the bottom - unless the buyer has scrolled away.
  const failures = pending.filter((p) => p.status === 'failed').length
  useEffect(() => {
    if (failures && nearLatest.current) scrollToLatest(smoothly())
  }, [failures, scrollToLatest])

  const submit = () => {
    const content = text.trim()
    if (sending.current || content.length < MIN_MESSAGE_LENGTH) return
    const id = nextId.current
    nextId.current = newKey()
    setPending((list) => [...list, { id, content, status: 'sending', at: new Date().toISOString() }])
    setText('')
    follow.current = smoothly()
    void deliver(id, content)
  }

  const retry = (id: string) => {
    const p = pending.find((x) => x.id === id)
    if (!p || sending.current) return
    follow.current = smoothly()
    void deliver(id, p.content)
  }

  const edit = (id: string) => {
    const p = pending.find((x) => x.id === id)
    if (!p) return
    setPending((list) => list.filter((x) => x.id !== id))
    setText((t) => (t.trim() ? `${t.trimEnd()}\n${p.content}` : p.content))
    inputRef.current?.focus()
  }

  const title = productName ? `Ask ${storeName} about ${productName}` : `Message ${storeName}`

  if (session.status !== 'signed_in') {
    return (
      <section className={styles.thread} aria-labelledby="enquiry-title" data-testid="enquiry-thread">
        <h2 id="enquiry-title" className="visually-hidden">
          {title}
        </h2>
        {header}
        {session.status === 'loading' ? (
          <div className={styles.history} aria-busy="true">
            <HistoryPlaceholder />
          </div>
        ) : (
          <div className={styles.signIn}>
            <SignInPanel
              title={`Sign in to message ${storeName}`}
              lead="We'll text you a code - no app needed. The store replies here and in the BROKA app."
            />
          </div>
        )}
      </section>
    )
  }

  return (
    <section className={styles.thread} aria-labelledby="enquiry-title" data-testid="enquiry-thread">
      <h2 id="enquiry-title" className="visually-hidden">
        {title}
      </h2>
      {header}
      <div
        ref={historyRef}
        className={styles.history}
        role="log"
        aria-label={`Messages with ${storeName}`}
        aria-busy={messages === null}
      >
        {messages === null && !loadError && <HistoryPlaceholder />}
        {messages === null && loadError && (
          <div className={styles.loadError} role="alert">
            <p>{loadError}</p>
            <button type="button" className="button button--ghost" onClick={() => void read()}>
              Try again
            </button>
          </div>
        )}
        {messages !== null && shown.length === 0 && (
          <div className={styles.emptyThread}>
            <span className={styles.emptyIcon} aria-hidden="true">
              <Icon name="chat" size={28} />
            </span>
            <p className={styles.emptyTitle}>
              {productName ? `Ask about ${productName}` : `Start a conversation with ${storeName}`}
            </p>
            <p className={styles.emptyText}>
              No messages yet. Ask about stock, delivery or sizes - {storeName} replies here and in the BROKA app.
            </p>
            <div className={styles.starters} role="group" aria-label="Start with">
              {STARTERS[productName ? 'product' : 'store'].map((s) => (
                <button
                  key={s}
                  type="button"
                  onClick={() => {
                    setText(s)
                    inputRef.current?.focus()
                  }}
                >
                  {s}
                </button>
              ))}
            </div>
          </div>
        )}
        {shown.length > 0 && (
          <MessageHistory messages={shown} storeName={storeName} storeLogo={storeLogo} onRetry={retry} onEdit={edit} />
        )}
        {messages !== null && loadError && (
          <p className={styles.refreshNote} role="status">
            Couldn&apos;t check for new messages just now - trying again shortly.
          </p>
        )}
        <div ref={endRef} className={styles.end} aria-hidden="true" />
      </div>
      {unseen && (
        <button
          type="button"
          className={styles.unseen}
          onClick={() => {
            scrollToLatest(smoothly())
            setUnseen(false)
          }}
        >
          <Icon name="down" size={16} /> New messages
        </button>
      )}
      <MessageComposer
        value={text}
        onChange={setText}
        onSend={submit}
        sending={busy}
        storeName={storeName}
        inputRef={inputRef}
        onFocusChange={(focused) => {
          typing.current = focused
        }}
      />
    </section>
  )
}

function HistoryPlaceholder() {
  return (
    <div className={styles.placeholder}>
      <span className="visually-hidden">Loading the conversation…</span>
      <span className={`skeleton ${styles.placeholderTheirs}`} />
      <span className={`skeleton ${styles.placeholderMine}`} />
      <span className={`skeleton ${styles.placeholderTheirs}`} />
    </div>
  )
}
