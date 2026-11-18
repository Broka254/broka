// A conversation with a store as the website draws it: the messages in
// days, consecutive ones from the same side within a few minutes drawn as
// one turn with one time under it, and - for a message that could not be
// sent - what to tell the buyer and whether sending it again is safe.
//
// Times are Kenya time on a 24-hour clock, as everywhere on the storefront
// (lib/orders.ts formatWhen), whatever the visitor's own clock is set to.

export type Side = 'buyer' | 'seller'

/** One message of the thread, as /api/stores/[id]/enquiries returns it. */
export interface ThreadMessage {
  id: string | null
  role: Side
  content: string
  /** text, image, voice, audio, file - photos and voice notes are shown as a mention. */
  kind: string
  created_at: string | null
  /** The id the buyer's browser gave its own message when it sent it. */
  client_msg_id?: string | null
}

/** The shortest question the API takes (stores/{id}/enquiries: ENQUIRY_EMPTY). */
export const MIN_MESSAGE_LENGTH = 2
export const MAX_MESSAGE_LENGTH = 2000

/** Messages from one side this close together read as one turn. */
export const TURN_GAP_MS = 5 * 60_000

const ZONE = 'Africa/Nairobi'
const dayParts = new Intl.DateTimeFormat('en-GB', { timeZone: ZONE, year: 'numeric', month: '2-digit', day: '2-digit' })
const clock = new Intl.DateTimeFormat('en-GB', { timeZone: ZONE, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })
const weekdayDayMonth = new Intl.DateTimeFormat('en-GB', { timeZone: ZONE, weekday: 'short', day: 'numeric', month: 'short' })
const dayMonth = new Intl.DateTimeFormat('en-GB', { timeZone: ZONE, day: 'numeric', month: 'short' })
const dayMonthYear = new Intl.DateTimeFormat('en-GB', { timeZone: ZONE, day: 'numeric', month: 'short', year: 'numeric' })
const weekday = new Intl.DateTimeFormat('en-GB', { timeZone: ZONE, weekday: 'short' })

function toDate(iso: string | null | undefined): Date | null {
  if (!iso) return null
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? null : d
}

/** "2026-11-17": the day in Kenya, comparable as a string. */
export function dayKey(d: Date): string {
  const parts = Object.fromEntries(dayParts.formatToParts(d).map((p) => [p.type, p.value]))
  return `${parts.year}-${parts.month}-${parts.day}`
}

const DAY_MS = 86_400_000

/** "14:05" */
export function timeLabel(iso: string | null | undefined): string {
  const d = toDate(iso)
  return d ? clock.format(d) : ''
}

/** A day's heading in the thread: "Today", "Yesterday", "Mon 16 Nov", "16 Nov 2025". */
export function dayLabel(iso: string | null | undefined, now: Date = new Date()): string {
  const d = toDate(iso)
  if (!d) return ''
  const key = dayKey(d)
  if (key === dayKey(now)) return 'Today'
  // Kenya keeps no summer time: a day is always 24 hours there.
  if (key === dayKey(new Date(now.getTime() - DAY_MS))) return 'Yesterday'
  return key.slice(0, 4) === dayKey(now).slice(0, 4) ? weekdayDayMonth.format(d) : dayMonthYear.format(d)
}

/** When a conversation last moved, for a list: "14:05", "Yesterday", "Mon", "12 Nov", "12 Nov 2025". */
export function listTime(iso: string | null | undefined, now: Date = new Date()): string {
  const d = toDate(iso)
  if (!d) return ''
  const label = dayLabel(iso, now)
  if (label === 'Today') return clock.format(d)
  if (label === 'Yesterday') return label
  const age = now.getTime() - d.getTime()
  if (age >= 0 && age < 6 * DAY_MS) return weekday.format(d)
  return dayKey(d).slice(0, 4) === dayKey(now).slice(0, 4) ? dayMonth.format(d) : dayMonthYear.format(d)
}

/** What the website shows for a message it cannot show itself. */
export function mention(kind: string): string | null {
  if (kind === 'text') return null
  if (kind === 'image') return '📷 A photo - open the BROKA app to see it.'
  return '🎙️ A voice note or file - open the BROKA app.'
}

export interface Turn<M extends ThreadMessage = ThreadMessage> {
  key: string
  role: Side
  messages: M[]
  /** The last message's time: the time shown under the turn. */
  at: string | null
}

export interface Day<M extends ThreadMessage = ThreadMessage> {
  key: string
  label: string
  turns: Turn<M>[]
}

/**
 * The thread in days and turns. Messages keep their order; a message with
 * no time (never from the API, but possible) stays in the day before it.
 */
export function daysOf<M extends ThreadMessage>(messages: readonly M[], now: Date = new Date()): Day<M>[] {
  const days: Day<M>[] = []
  let lastTime: number | null = null
  messages.forEach((m, i) => {
    const d = toDate(m.created_at)
    const key = d ? dayKey(d) : days.at(-1)?.key ?? dayKey(now)
    let day = days.at(-1)
    if (!day || day.key !== key) {
      day = { key, label: d ? dayLabel(m.created_at, now) : 'Today', turns: [] }
      days.push(day)
      lastTime = null
    }
    const turn = day.turns.at(-1)
    const t = d?.getTime() ?? null
    const close = turn && turn.role === m.role && (t === null || lastTime === null || t - lastTime <= TURN_GAP_MS)
    if (turn && close) {
      turn.messages.push(m)
      if (m.created_at) turn.at = m.created_at
    } else {
      day.turns.push({ key: `${key}-${m.id ?? m.client_msg_id ?? i}`, role: m.role, messages: [m], at: m.created_at })
    }
    if (t !== null) lastTime = t
  })
  return days
}

export interface SendFailure {
  /** What the buyer reads under the message. */
  message: string
  /**
   * Whether sending it again is safe and might work: the same id goes
   * again, and the chat engine answers a repeat with the message it already
   * stored, so a retry can never post the question twice. A refusal (the
   * store is closed, the product is not the store's) would only be refused
   * again: the buyer edits it instead.
   */
  retryable: boolean
}

/** Why a message did not go, in the buyer's words, from the storefront API's answer. */
export function sendFailure(status: number, error: { code?: string; message?: string }): SendFailure {
  if (status === 0) {
    return { message: "Not sent - couldn't reach BROKA. Check your connection, then try again.", retryable: true }
  }
  if (status === 429 || error.code === 'RATE_LIMITED') {
    // The API's own words here name its limiter ("Too many store_enquiry
    // attempts. Limit: 12 per 600s.") - true, but not for a buyer.
    return {
      message: "Not sent - you've sent several messages in a short time. Wait a few minutes, then try again.",
      retryable: true,
    }
  }
  if (status === 401) return { message: 'Not sent - you were signed out. Sign in again to send it.', retryable: false }
  if (status >= 500) return { message: "Not sent - BROKA couldn't take it just now. Try again in a moment.", retryable: true }
  return { message: error.message ? `Not sent - ${error.message}` : 'Not sent.', retryable: false }
}
