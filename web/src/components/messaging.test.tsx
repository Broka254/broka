import { act, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type { Conversation } from '@/lib/conversations'
import { resetSession } from '@/lib/session-client'
import { type Call, json, SIGNED_IN, stubFetch } from '@/test/fixtures'

import { EnquiryThread } from './EnquiryThread'
import { InboxView } from './InboxView'

const THREAD = '/api/stores/s1/enquiries'
const at = (minute: number) => new Date(Date.UTC(2026, 10, 18, 5, minute)).toISOString()
const message = (id: string, role: 'buyer' | 'seller', content: string, minute: number, over: Record<string, unknown> = {}) => ({
  id,
  role,
  content,
  kind: 'text',
  created_at: at(minute),
  ...over,
})

// jsdom draws nothing, so where the page is scrolled to is set by hand: the
// page is `pageHeight` tall in a 768px window, scrolled to the top.
const scrolled = vi.fn()
let pageHeight = 768
const originalScrollIntoView = Element.prototype.scrollIntoView

beforeEach(() => {
  resetSession()
  scrolled.mockClear()
  pageHeight = 768
  Element.prototype.scrollIntoView = scrolled
  Object.defineProperty(document.documentElement, 'scrollHeight', { configurable: true, get: () => pageHeight })
  Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'visible' })
})

afterEach(() => {
  if (originalScrollIntoView) Element.prototype.scrollIntoView = originalScrollIntoView
  else delete (Element.prototype as { scrollIntoView?: unknown }).scrollIntoView
  delete (document.documentElement as { scrollHeight?: unknown }).scrollHeight
  delete (document as { visibilityState?: unknown }).visibilityState
})

/** A computer (a fine pointer: Enter sends) or a phone (Enter is a new line). */
function device(kind: 'computer' | 'phone') {
  vi.stubGlobal('matchMedia', (query: string) => ({
    matches: kind === 'computer' && query.includes('pointer: fine'),
    media: query,
    addEventListener: () => {},
    removeEventListener: () => {},
  }))
}

const box = async () => (await screen.findByLabelText('Your message')) as HTMLTextAreaElement
const sendButton = () => screen.getByRole('button', { name: 'Send' }) as HTMLButtonElement

describe('writing to a store', () => {
  it('shows a message the moment it is sent, marked Sending, then the stored copy in its place - never both', async () => {
    let release!: () => void
    const gate = new Promise<void>((resolve) => {
      release = resolve
    })
    let stored: Array<Record<string, unknown>> = []
    const stub = stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      [THREAD]: async (c: Call) => {
        if (c.method === 'GET') return json({ messages: stored })
        await gate
        const id = (c.body as { client_msg_id: string }).client_msg_id
        stored = [message('m9', 'buyer', 'Hello there', 5, { client_msg_id: id })]
        return json({ ok: true, message: { id: 'm9' } }, 201)
      },
    })
    render(<EnquiryThread storeId="s1" storeName="Clanix" />)
    const input = await box()
    fireEvent.change(input, { target: { value: '  Hello there  ' } })
    fireEvent.click(sendButton())

    expect(screen.getByText('Hello there')).toBeTruthy()
    expect(screen.getByText('Sending…')).toBeTruthy()
    expect(input.value).toBe('')

    release()
    await waitFor(() => expect(stub.to(THREAD, 'GET').length).toBeGreaterThanOrEqual(2))
    await waitFor(() => expect(screen.queryByText('Sending…')).toBeNull())
    expect(screen.getAllByText('Hello there')).toHaveLength(1)
    expect(stub.to(THREAD, 'POST')[0]!.body).toMatchObject({ content: 'Hello there' })
  })

  it('waits for a message on its way before sending the next: a double tap or Enter cannot send twice', async () => {
    let release!: () => void
    const gate = new Promise<void>((resolve) => {
      release = resolve
    })
    const stub = stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      [THREAD]: async (c: Call) => {
        if (c.method === 'GET') return json({ messages: [] })
        await gate
        return json({ ok: true, message: { id: `m${Math.random()}` } }, 201)
      },
    })
    render(<EnquiryThread storeId="s1" storeName="Clanix" />)
    const input = await box()
    fireEvent.change(input, { target: { value: 'Is it available?' } })
    fireEvent.click(sendButton())
    fireEvent.click(sendButton())

    // The next one is written while the first is still on its way.
    fireEvent.change(input, { target: { value: 'And in blue?' } })
    expect(sendButton().disabled).toBe(true)
    fireEvent.keyDown(input, { key: 'Enter' })
    fireEvent.submit(input.closest('form')!)
    expect(stub.to(THREAD, 'POST')).toHaveLength(1)

    release()
    await waitFor(() => expect(sendButton().disabled).toBe(false))
    fireEvent.click(sendButton())
    await waitFor(() => expect(stub.to(THREAD, 'POST')).toHaveLength(2))
    expect(stub.to(THREAD, 'POST').map((c) => (c.body as { content: string }).content)).toEqual(['Is it available?', 'And in blue?'])
  })

  it('on a computer Enter sends and Shift+Enter is a new line; on a phone Enter is a new line', async () => {
    device('computer')
    const stub = stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      [THREAD]: (c: Call) => (c.method === 'GET' ? json({ messages: [] }) : json({ ok: true, message: { id: 'm9' } }, 201)),
    })
    const { unmount } = render(<EnquiryThread storeId="s1" storeName="Clanix" />)
    let input = await box()
    fireEvent.change(input, { target: { value: 'First line' } })
    fireEvent.keyDown(input, { key: 'Enter', shiftKey: true })
    expect(stub.to(THREAD, 'POST')).toHaveLength(0)
    fireEvent.keyDown(input, { key: 'Enter' })
    await waitFor(() => expect(stub.to(THREAD, 'POST')).toHaveLength(1))
    unmount()

    device('phone')
    render(<EnquiryThread storeId="s1" storeName="Clanix" />)
    input = await box()
    fireEvent.change(input, { target: { value: 'On a phone' } })
    fireEvent.keyDown(input, { key: 'Enter' })
    expect(stub.to(THREAD, 'POST')).toHaveLength(1)
    fireEvent.click(sendButton())
    await waitFor(() => expect(stub.to(THREAD, 'POST')).toHaveLength(2))
  })

  it('will not send an empty message, or one too short to be a question', async () => {
    const stub = stubFetch({ '/api/stores/session': json(SIGNED_IN), [THREAD]: json({ messages: [] }) })
    render(<EnquiryThread storeId="s1" storeName="Clanix" />)
    const input = await box()
    expect(sendButton().disabled).toBe(true)
    fireEvent.change(input, { target: { value: '   a   ' } })
    expect(sendButton().disabled).toBe(true)
    fireEvent.keyDown(input, { key: 'Enter' })
    expect(stub.to(THREAD, 'POST')).toHaveLength(0)
  })

  it('brings a failed message, with its reason and Retry, into view', async () => {
    stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      [THREAD]: (c: Call) =>
        c.method === 'GET'
          ? json({ messages: [] })
          : json({ error: { code: 'RATE_LIMITED', message: 'Too many tries.' } }, 429),
    })
    render(<EnquiryThread storeId="s1" storeName="Clanix" />)
    fireEvent.change(await box(), { target: { value: 'Can you deliver it this evening?' } })
    fireEvent.click(sendButton())
    // Once to the message as it is sent...
    await waitFor(() => expect(scrolled).toHaveBeenCalledTimes(1))
    await screen.findByRole('button', { name: 'Retry' })
    // ...and again once it has grown by its reason and its Retry.
    await waitFor(() => expect(scrolled).toHaveBeenCalledTimes(2))
  })

  it('a refusal is not retried - the buyer gets the message back to change it', async () => {
    const stub = stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      [THREAD]: (c: Call) =>
        c.method === 'GET'
          ? json({ messages: [] })
          : json({ error: { code: 'STORE_NOT_OPEN', message: "Clanix isn't open right now." } }, 409),
    })
    render(<EnquiryThread storeId="s1" storeName="Clanix" />)
    const input = await box()
    fireEvent.change(input, { target: { value: 'Is it in stock?' } })
    fireEvent.click(sendButton())
    expect((await screen.findByRole('alert')).textContent).toContain("Not sent - Clanix isn't open right now.")
    expect(screen.queryByRole('button', { name: 'Retry' })).toBeNull()

    fireEvent.click(screen.getByRole('button', { name: 'Edit' }))
    expect(input.value).toBe('Is it in stock?')
    expect(screen.queryByRole('alert')).toBeNull()
    expect(stub.to(THREAD, 'POST')).toHaveLength(1)
  })

  it('keeps what the buyer was writing when they look at the product and come back', async () => {
    stubFetch({ '/api/stores/session': json(SIGNED_IN), [THREAD]: json({ messages: [] }) })
    const thread = <EnquiryThread storeId="s1" storeName="Clanix" listingId="l1" productName="Samsung A15" />
    const { unmount } = render(thread)
    fireEvent.change(await box(), { target: { value: 'Is the blue one' } })
    unmount()
    render(thread)
    expect((await box()).value).toBe('Is the blue one')
  })

  it('an empty conversation suggests how to start, and a suggestion fills the box', async () => {
    stubFetch({ '/api/stores/session': json(SIGNED_IN), [THREAD]: json({ messages: [] }) })
    render(<EnquiryThread storeId="s1" storeName="Clanix" listingId="l1" productName="Samsung A15" />)
    expect(await screen.findByText('Ask about Samsung A15')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Is it still available?' }))
    expect((await box()).value).toBe('Is it still available?')
  })
})

describe('reading a conversation', () => {
  it('opens at the newest message, then follows new ones only while the buyer is at the bottom', async () => {
    let thread = [message('m1', 'buyer', 'Is it in stock?', 0), message('m2', 'seller', 'Yes, two left.', 1)]
    const stub = stubFetch({ '/api/stores/session': json(SIGNED_IN), [THREAD]: () => json({ messages: thread }) })
    let later = 0
    const realNow = Date.now.bind(Date)
    vi.spyOn(Date, 'now').mockImplementation(() => realNow() + later)
    const readAgain = async () => {
      // Back on the tab: the thread is read again (and every 20 seconds).
      const reads = stub.to(THREAD, 'GET').length
      later += 10_000
      act(() => {
        document.dispatchEvent(new Event('visibilitychange'))
      })
      await waitFor(() => expect(stub.to(THREAD, 'GET').length).toBe(reads + 1))
    }

    render(<EnquiryThread storeId="s1" storeName="Clanix" />)
    await screen.findByText('Yes, two left.')
    // Opened at the newest message.
    await waitFor(() => expect(scrolled).toHaveBeenCalledTimes(1))

    // The buyer scrolls up to read; the store answers meanwhile.
    pageHeight = 4000
    fireEvent.scroll(window)
    thread = [...thread, message('m3', 'seller', 'Do you want it delivered?', 2)]
    await readAgain()
    await screen.findByText('Do you want it delivered?')
    // Not pulled down while reading: a button says there is more.
    const more = await screen.findByRole('button', { name: 'New messages' })
    expect(scrolled).toHaveBeenCalledTimes(1)
    fireEvent.click(more)
    expect(scrolled).toHaveBeenCalledTimes(2)
    expect(screen.queryByRole('button', { name: 'New messages' })).toBeNull()

    // At the bottom again, the next answer is followed.
    pageHeight = 800
    fireEvent.scroll(window)
    thread = [...thread, message('m4', 'seller', 'Delivery is KES 200.', 3)]
    await readAgain()
    await screen.findByText('Delivery is KES 200.')
    await waitFor(() => expect(scrolled).toHaveBeenCalledTimes(3))
    expect(screen.queryByRole('button', { name: 'New messages' })).toBeNull()
  })

  it("draws the buyer's and the store's messages apart, in turns, with the store's sign and the times", async () => {
    stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      [THREAD]: json({
        messages: [
          message('m1', 'buyer', 'Is it in stock?', 0),
          message('m2', 'buyer', 'And the charger?', 1),
          message('m3', 'seller', 'Yes, both.', 30),
        ],
      }),
    })
    render(<EnquiryThread storeId="s1" storeName="Clanix" />)
    const log = await screen.findByRole('log', { name: 'Messages with Clanix' })
    await screen.findByText('Yes, both.')
    const turns = [...log.querySelectorAll('li > ol > li')]
    expect(turns.map((t) => t.textContent)).toEqual([
      // Two messages a minute apart are one turn, under one time.
      'Is it in stock?And the charger?You · 08:01',
      'CYes, both.Clanix · 08:30',
    ])
  })
})

describe("the buyer's messages from every store", () => {
  const conversation = (over: Partial<Conversation> = {}): Conversation => ({
    key: 'store:s1',
    store: { id: 's1', slug: 'clanix', name: 'Clanix', logo: null },
    product: null,
    last: { text: 'Yes, two left.', from: 'seller', at: at(1) },
    href: '/store/clanix/messages',
    ...over,
  })

  it("lists each conversation with its store, what it is about and its last line, each opening on its store's page", async () => {
    const stub = stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/conversations': json({
        conversations: [
          conversation(),
          conversation({
            key: 'product:l1',
            store: { id: 's2', slug: 'java', name: 'Java', logo: null },
            product: { id: 'l1', name: 'Office chair', image: null },
            last: { text: 'Do you deliver?', from: 'buyer', at: at(0) },
            href: '/store/java/messages?product=l1',
          }),
        ],
        partial: false,
      }),
    })
    render(<InboxView />)
    const rows = await screen.findAllByTestId('conversation')
    expect(rows.map((r) => r.getAttribute('href'))).toEqual(['/store/clanix/messages', '/store/java/messages?product=l1'])
    expect(rows[0]!.textContent).toContain('Clanix')
    expect(rows[0]!.textContent).toContain('Store conversation')
    expect(rows[0]!.textContent).toContain('Yes, two left.')
    expect(rows[1]!.textContent).toContain('About Office chair')
    expect(rows[1]!.textContent).toContain('You: Do you deliver?')
    expect(stub.to('/api/stores/conversations')[0]!.url).toBe('/api/stores/conversations?user=u1')
  })

  it('says when there are none yet, and how a conversation starts', async () => {
    stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/conversations': json({ conversations: [], partial: false }),
    })
    render(<InboxView />)
    expect(await screen.findByRole('heading', { name: 'No conversations yet' })).toBeTruthy()
  })

  it('says what went wrong, Try again reads the list again, and an incomplete list says so', async () => {
    let attempt = 0
    stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/conversations': () =>
        ++attempt === 1
          ? json({ error: { code: 'API_UNREACHABLE', message: "Couldn't reach BROKA." } }, 503)
          : json({ conversations: [conversation()], partial: true }),
    })
    render(<InboxView />)
    expect((await screen.findByRole('alert')).textContent).toContain("Couldn't reach BROKA.")
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }))
    expect(await screen.findByTestId('conversation')).toBeTruthy()
    expect(screen.getByRole('status').textContent).toContain("Some conversations couldn't be loaded just now.")
  })

  it('asks a signed-out visitor to sign in, and reads no conversations', async () => {
    const stub = stubFetch({ '/api/stores/session': json({ signed_in: false }) })
    render(<InboxView />)
    expect(await screen.findByRole('heading', { name: 'Sign in to see your messages' })).toBeTruthy()
    expect(stub.to('/api/stores/conversations')).toHaveLength(0)
  })
})
