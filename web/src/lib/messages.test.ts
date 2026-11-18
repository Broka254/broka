import { describe, expect, it } from 'vitest'

import { dayLabel, daysOf, listTime, mention, sendFailure, type ThreadMessage, timeLabel } from './messages'

// 10:00 on Wednesday 18 November 2026 in Nairobi (UTC+3).
const NOW = new Date('2026-11-18T07:00:00Z')

const msg = (id: string, role: 'buyer' | 'seller', at: string, over: Partial<ThreadMessage> = {}): ThreadMessage => ({
  id,
  role,
  content: `message ${id}`,
  kind: 'text',
  created_at: at,
  ...over,
})

describe('times in a conversation', () => {
  it('are Kenya time on a 24-hour clock, whatever the visitor\'s clock says', () => {
    expect(timeLabel('2026-11-18T05:04:00Z')).toBe('08:04')
    expect(timeLabel('2026-11-17T21:30:00Z')).toBe('00:30')
    expect(timeLabel(null)).toBe('')
    expect(timeLabel('not a date')).toBe('')
  })

  it('names the day as people say it: today, yesterday, then the date', () => {
    expect(dayLabel('2026-11-18T05:00:00Z', NOW)).toBe('Today')
    // 22:00 UTC on the 17th is already the 18th in Nairobi.
    expect(dayLabel('2026-11-17T22:00:00Z', NOW)).toBe('Today')
    expect(dayLabel('2026-11-17T20:00:00Z', NOW)).toBe('Yesterday')
    expect(dayLabel('2026-11-12T09:00:00Z', NOW)).toBe('Thu 12 Nov')
    expect(dayLabel('2025-12-24T09:00:00Z', NOW)).toBe('24 Dec 2025')
  })

  it('a list of conversations shows the time today, the weekday this week, the date before that', () => {
    expect(listTime('2026-11-18T05:04:00Z', NOW)).toBe('08:04')
    expect(listTime('2026-11-17T09:00:00Z', NOW)).toBe('Yesterday')
    expect(listTime('2026-11-14T09:00:00Z', NOW)).toBe('Sat')
    expect(listTime('2026-11-02T09:00:00Z', NOW)).toBe('2 Nov')
    expect(listTime('2025-11-02T09:00:00Z', NOW)).toBe('2 Nov 2025')
    expect(listTime(null, NOW)).toBe('')
  })
})

describe('a conversation in days and turns', () => {
  it('draws consecutive messages from one side, minutes apart, as one turn under the last one\'s time', () => {
    const days = daysOf(
      [
        msg('a', 'buyer', '2026-11-18T05:00:00Z'),
        msg('b', 'buyer', '2026-11-18T05:02:00Z'),
        msg('c', 'seller', '2026-11-18T05:03:00Z'),
        msg('d', 'seller', '2026-11-18T05:30:00Z'),
      ],
      NOW,
    )
    expect(days).toHaveLength(1)
    expect(days[0]!.label).toBe('Today')
    expect(days[0]!.turns.map((t) => [t.role, t.messages.map((m) => m.id), t.at])).toEqual([
      ['buyer', ['a', 'b'], '2026-11-18T05:02:00Z'],
      ['seller', ['c'], '2026-11-18T05:03:00Z'],
      // Half an hour later: a new turn, with its own time.
      ['seller', ['d'], '2026-11-18T05:30:00Z'],
    ])
  })

  it('starts a new day at midnight in Kenya, even within a turn', () => {
    const days = daysOf(
      [msg('a', 'buyer', '2026-11-17T20:58:00Z'), msg('b', 'buyer', '2026-11-17T21:01:00Z')],
      NOW,
    )
    expect(days.map((d) => [d.label, d.turns.flatMap((t) => t.messages.map((m) => m.id))])).toEqual([
      ['Yesterday', ['a']],
      ['Today', ['b']],
    ])
  })

  it('keeps every message in order, with a key for each turn, and nothing for an empty thread', () => {
    expect(daysOf([], NOW)).toEqual([])
    const days = daysOf([msg('a', 'buyer', '2026-11-18T05:00:00Z'), msg('b', 'seller', '2026-11-18T05:01:00Z')], NOW)
    const keys = days.flatMap((d) => d.turns.map((t) => t.key))
    expect(new Set(keys).size).toBe(keys.length)
  })
})

describe('what the website shows for a message it cannot show', () => {
  it('names a photo, a voice note or a file, and shows text as it is', () => {
    expect(mention('text')).toBeNull()
    expect(mention('image')).toBe('📷 A photo - open the BROKA app to see it.')
    expect(mention('voice')).toBe('🎙️ A voice note or file - open the BROKA app.')
  })
})

describe('a message that could not be sent', () => {
  it('offers to send again when that is safe and may work: no connection, too many at once, a server hiccup', () => {
    for (const [status, error] of [
      [0, { code: 'NETWORK', message: "Couldn't reach BROKA" }],
      [429, { code: 'HTTP_429', message: 'Too many store_enquiry attempts. Limit: 12 per 600s.' }],
      [503, { code: 'API_UNREACHABLE', message: "Couldn't reach BROKA." }],
    ] as const) {
      const failure = sendFailure(status, error)
      expect(failure.retryable).toBe(true)
      expect(failure.message).toMatch(/^Not sent - /)
    }
    // The limiter's own wording is for engineers, not buyers.
    expect(sendFailure(429, { message: 'Too many store_enquiry attempts. Limit: 12 per 600s.' }).message).not.toContain(
      'store_enquiry',
    )
  })

  it("passes on the store's refusal, without a retry that would only be refused again", () => {
    const failure = sendFailure(409, { code: 'STORE_NOT_OPEN', message: "Clanix isn't open right now." })
    expect(failure).toEqual({ message: "Not sent - Clanix isn't open right now.", retryable: false })
    expect(sendFailure(401, { code: 'SIGNED_OUT' }).retryable).toBe(false)
  })
})
