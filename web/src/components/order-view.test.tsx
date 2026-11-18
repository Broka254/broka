import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { beforeEach, describe, expect, it } from 'vitest'

import { type EscrowDirectory, REQUIRED_NOTICE } from '@/lib/escrow-providers'
import { type Order, orderTone } from '@/lib/orders'
import { resetSession } from '@/lib/session-client'
import { json, order, SIGNED_IN, stubFetch } from '@/test/fixtures'

import { OrderView } from './OrderView'

beforeEach(() => resetSession())

const escrow: EscrowDirectory = {
  providers: [
    {
      id: 'p1',
      name: 'Example Escrow',
      url: 'https://escrow.example.co.ke/',
      reviewLabel: 'Under review',
      feeSummary: 'Fee not publicly specified - confirm before paying',
      summary: '',
      warning: null,
      notToBeConfusedWith: null,
    },
  ],
  disclaimer: REQUIRED_NOTICE,
  notices: [],
}

/** The order page for [current]; every action answers with [after] (or [current]). */
function openOrder(current: Order, after?: Order) {
  const stub = stubFetch({
    '/api/stores/session': json(SIGNED_IN),
    '/api/stores/orders/o1': (c) => (c.method === 'GET' ? json(current) : json(after ?? current)),
  })
  render(<OrderView orderId="o1" escrow={escrow} />)
  return stub
}

const button = (name: string | RegExp) => screen.getByRole('button', { name })

describe('OrderView', () => {
  it('shows where the order is, what the store said, and the total the API worked out', async () => {
    openOrder(order())
    expect(await screen.findByTestId('order-view')).toBeTruthy()
    expect(screen.getByRole('heading', { level: 1 }).textContent).toBe('Waiting for your confirmation')
    expect(screen.getByTestId('order-status').textContent).toBe('awaiting buyer confirmation')
    expect(screen.getByTestId('order-total').textContent).toBe('KES 15,300')
    expect(screen.getByText('Samsung A15')).toBeTruthy()
    expect(screen.getByText(/Only one in stock\./)).toBeTruthy()
  })

  it('says in words what the store changed, not only in colour', async () => {
    openOrder(order())
    const row = (await screen.findByText('Samsung A15')).closest('li')!
    expect(row.textContent).toMatch(/You asked for 2\s*the store offers 1/)
  })

  it('says when the store cannot supply a product at all', async () => {
    const base = order()
    openOrder(order({ items: [{ ...base.items[0]!, removed: true, quantity: 0, line_total_minor: 0 }] }))
    expect(await screen.findByText("The store can't supply this one.")).toBeTruthy()
  })

  it('offers only the actions the API says the order allows now', async () => {
    openOrder(order({ allowed_actions: ['cancel'] }))
    await screen.findByTestId('order-view')
    expect(screen.queryByRole('button', { name: /Confirm order/ })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Reject the changes' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'I received it' })).toBeNull()
    expect(button('Cancel order')).toBeTruthy()
  })

  it('confirming takes two steps, says what it means, and sends the revision the buyer saw', async () => {
    const confirmed = order({
      status: 'confirmed',
      status_label: 'Confirmed',
      allowed_actions: ['cancel'],
      totals: { ...order().totals, final: true },
    })
    const stub = openOrder(order(), confirmed)
    await screen.findByTestId('order-view')

    fireEvent.click(button('Confirm order - KES 15,300'))
    const ask = screen.getByRole('group', { name: 'Confirm your choice' })
    expect(ask.textContent).toContain('KES 15,300')
    expect(ask.textContent).toContain("Payment is between you and the store - BROKA doesn't take it.")
    // Asking sends nothing.
    expect(stub.to('/api/stores/orders/o1/confirm')).toHaveLength(0)

    fireEvent.click(button('Yes, confirm the order'))
    await waitFor(() => expect(screen.getByTestId('order-status').textContent).toBe('confirmed'))
    const sent = stub.to('/api/stores/orders/o1/confirm', 'POST')
    expect(sent).toHaveLength(1)
    expect(sent[0]!.body).toEqual({ revision: 2 })
    expect(sent[0]!.headers['x-broka-web']).toBe('1')
    expect(screen.queryByRole('button', { name: /Confirm order/ })).toBeNull()
  })

  it('"Not now" goes back without sending anything', async () => {
    const stub = openOrder(order())
    await screen.findByTestId('order-view')
    fireEvent.click(button(/Confirm order/))
    fireEvent.click(button('Not now'))
    expect(screen.queryByRole('group', { name: 'Confirm your choice' })).toBeNull()
    expect(button(/Confirm order/)).toBeTruthy()
    expect(stub.to('/api/stores/orders/o1', 'POST')).toHaveLength(0)
  })

  it('cancelling asks first, takes a reason, and shows who ended the order', async () => {
    const cancelled = order({
      status: 'cancelled',
      status_label: 'Cancelled',
      open: false,
      allowed_actions: [],
      cancelled_by: 'buyer',
      cancel_reason: 'Found it cheaper',
    })
    const stub = openOrder(order(), cancelled)
    await screen.findByTestId('order-view')
    fireEvent.click(button('Cancel order'))
    expect(screen.getByRole('group', { name: 'Confirm your choice' }).textContent).toContain("can't be reopened")
    fireEvent.change(screen.getByLabelText('Tell the store why (optional)'), { target: { value: 'Found it cheaper' } })
    fireEvent.click(button('Yes, cancel the order'))
    expect(await screen.findByText(/Cancelled by you: Found it cheaper/)).toBeTruthy()
    expect(stub.to('/api/stores/orders/o1/cancel', 'POST')[0]!.body).toEqual({ reason: 'Found it cheaper' })
    // An order that ended has nothing to pay.
    expect(screen.queryByTestId('payment')).toBeNull()
  })

  it('rejecting the changes sends them back to the store, with the reason', async () => {
    const stub = openOrder(order({ status: 'seller_proposed_changes', status_label: 'The store changed your order' }))
    expect((await screen.findByRole('status')).textContent).toContain('nothing goes ahead unless you confirm')
    fireEvent.click(button('Reject the changes'))
    fireEvent.change(screen.getByLabelText('Tell the store why (optional)'), { target: { value: 'Too expensive' } })
    fireEvent.click(button('Yes, reject the changes'))
    await waitFor(() => expect(stub.to('/api/stores/orders/o1/reject-proposal', 'POST')).toHaveLength(1))
    expect(stub.to('/api/stores/orders/o1/reject-proposal')[0]!.body).toEqual({ note: 'Too expensive' })
  })

  it('when the store changed its offer meanwhile, says so and reads the order again', async () => {
    const stub = stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/orders/o1': (c) =>
        c.method === 'GET'
          ? json(order())
          : json({ error: { code: 'ORDER_REVISION_STALE', message: 'The store changed its offer. Check the new details.' } }, 409),
    })
    render(<OrderView orderId="o1" escrow={escrow} />)
    await screen.findByTestId('order-view')
    fireEvent.click(button(/Confirm order/))
    fireEvent.click(button('Yes, confirm the order'))
    expect((await screen.findByTestId('order-error')).textContent).toBe('The store changed its offer. Check the new details.')
    await waitFor(() => expect(stub.to('/api/stores/orders/o1', 'GET')).toHaveLength(2))
  })

  it('"I received it" asks first, and completes the order only on a yes', async () => {
    const delivered = order({ status: 'delivered', status_label: 'Delivered', allowed_actions: ['confirm_received', 'report_problem'] })
    const done = order({ status: 'completed', status_label: 'Completed', open: false, allowed_actions: [] })
    const stub = openOrder(delivered, done)
    await screen.findByTestId('order-view')
    fireEvent.click(button('I received it'))
    expect(screen.getByRole('group', { name: 'Confirm your choice' }).textContent).toContain('Confirm only once you have everything')
    expect(stub.to('/api/stores/orders/o1/received')).toHaveLength(0)
    fireEvent.click(button('Yes, I have it'))
    await waitFor(() => expect(screen.getByTestId('order-status').textContent).toBe('completed'))
    expect(stub.to('/api/stores/orders/o1/received', 'POST')[0]!.body).toEqual({})
  })

  it('reports a problem with a note of a few words at least', async () => {
    const delivered = order({ status: 'delivered', status_label: 'Delivered', allowed_actions: ['confirm_received', 'report_problem'] })
    const stub = openOrder(delivered)
    await screen.findByTestId('order-view')
    fireEvent.click(button('Report a problem'))
    const send = button('Send to the store') as HTMLButtonElement
    expect(send.disabled).toBe(true)
    fireEvent.change(screen.getByLabelText('What went wrong?'), { target: { value: 'Wrong colour' } })
    expect(send.disabled).toBe(false)
    fireEvent.click(send)
    await waitFor(() => expect(stub.to('/api/stores/orders/o1/problem', 'POST')).toHaveLength(1))
    expect(stub.to('/api/stores/orders/o1/problem')[0]!.body).toEqual({ note: 'Wrong colour' })
  })

  it('a declined order says why, and has nothing to pay', async () => {
    openOrder(order({ status: 'declined', status_label: 'Declined', open: false, allowed_actions: [], decline_reason: 'Out of stock' }))
    expect(await screen.findByText('Declined: Out of stock')).toBeTruthy()
    expect(screen.queryByTestId('payment')).toBeNull()
    expect(screen.queryByRole('button', { name: /Confirm order|Cancel order/ })).toBeNull()
  })

  it('asks a signed-out visitor to sign in, and asks the API for no order', async () => {
    const stub = stubFetch({ '/api/stores/session': json({ signed_in: false }) })
    render(<OrderView orderId="o1" escrow={escrow} />)
    expect(await screen.findByTestId('sign-in')).toBeTruthy()
    expect(stub.to('/api/stores/orders')).toHaveLength(0)
  })

  it("an order that isn't the buyer's reads as not found, with the way back", async () => {
    stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/orders/o1': json({ error: { code: 'ORDER_NOT_FOUND', message: 'Order not found' } }, 404),
    })
    render(<OrderView orderId="o1" escrow={escrow} />)
    expect((await screen.findByRole('alert')).textContent).toBe("We couldn't find that order on your account.")
    expect(screen.getByRole('link', { name: 'See your orders' }).getAttribute('href')).toBe('/store/orders')
  })

  it("keeps the store in reach: its page, a message about the order, and each product's own page", async () => {
    openOrder(order())
    const store = await screen.findByTestId('order-store')
    expect(store.textContent).toContain('Clanix')
    expect(within(store).getByRole('link', { name: /Visit the store/ }).getAttribute('href')).toBe('/store/clanix')
    expect(within(store).getByRole('link', { name: 'Message Clanix about this order' }).getAttribute('href')).toBe(
      '/store/clanix/messages',
    )
    expect(screen.getByRole('link', { name: 'Samsung A15' }).getAttribute('href')).toBe('/store/clanix/p/l1')
    expect(screen.getByRole('link', { name: /All orders/ }).getAttribute('href')).toBe('/store/orders')
  })

  it('an order whose store has no link any more names it, and links nowhere', async () => {
    const base = order()
    openOrder(order({ store: { ...base.store, slug: null, url: null } }))
    const store = await screen.findByTestId('order-store')
    expect(store.textContent).toContain('Clanix')
    expect(within(store).queryAllByRole('link')).toHaveLength(0)
    expect(screen.queryByRole('link', { name: 'Samsung A15' })).toBeNull()
    expect(screen.getByText('Samsung A15')).toBeTruthy()
  })

  it('goes back to signing in when the session ends while the page is open', async () => {
    let sessions = 0
    const stub = stubFetch({
      '/api/stores/session': () => (++sessions === 1 ? json(SIGNED_IN) : json({ signed_in: false })),
      '/api/stores/orders/o1': json({ error: { code: 'SIGNED_OUT', message: 'Sign in to continue.' } }, 401),
    })
    render(<OrderView orderId="o1" escrow={escrow} />)
    expect(await screen.findByTestId('sign-in')).toBeTruthy()
    expect(stub.to('/api/stores/orders/o1', 'GET')).toHaveLength(1)
  })
})

describe("an order's status badge", () => {
  it('is coloured by what the status means for the buyer - and changes nothing about the status itself', () => {
    expect(orderTone('awaiting_buyer_confirmation', true)).toBe('action')
    expect(orderTone('delivered', true)).toBe('action')
    expect(orderTone('submitted', false)).toBe('progress')
    expect(orderTone('preparing', false)).toBe('progress')
    expect(orderTone('completed', false)).toBe('done')
    for (const ended of ['declined', 'cancelled', 'expired'] as const) expect(orderTone(ended, false)).toBe('ended')
    // An ended order is ended, whatever is said to be waiting.
    expect(orderTone('expired', true)).toBe('ended')
  })

  it('on the order, the words are still the status as the API names it', async () => {
    openOrder(order({ status: 'completed', status_label: 'Completed', open: false, allowed_actions: [] }))
    const badge = await screen.findByTestId('order-status')
    expect(badge.textContent).toBe('completed')
    expect(badge.getAttribute('data-tone')).toBe('done')
  })
})

describe('OrderView: paying', () => {
  const providerNotice =
    'This escrow provider is independent of BROKA. Check its own fees, terms, protections and process on its official website before you pay.'
  const confirmed = (payment: Partial<Order['payment']>) =>
    order({
      status: 'confirmed',
      status_label: 'Confirmed',
      allowed_actions: ['cancel'],
      payment: { ...order().payment, ...payment },
    })

  const escrowProvider = {
    id: 'p1',
    name: 'Example Escrow',
    url: 'https://escrow.example.co.ke/',
    domain: 'escrow.example.co.ke',
    independent: true,
    notice: providerNotice,
  }

  const withEscrow = confirmed({
    arrangement: 'independent_escrow',
    arrangement_label: 'Independent escrow provider',
    provider: escrowProvider,
    reports: [
      {
        kind: 'buyer_reported_escrow_initiated',
        label: 'Buyer reported escrow initiated',
        actor_role: 'buyer',
        reference: 'TX123',
        note: null,
        created_at: '2026-11-17T09:00:00+00:00',
        verified: false,
      },
    ],
    summary: { label: 'Awaiting external confirmation', awaiting_external_confirmation: true, status_note: null, verified: false },
    can_choose: false,
    allowed_reports: [],
  })

  it('shows a payment as what someone reported, awaiting confirmation outside BROKA - never as verified', async () => {
    openOrder(withEscrow)
    const payment = await screen.findByTestId('payment')
    expect(within(payment).getByTestId('payment-summary').textContent).toBe('Awaiting external confirmation')
    expect(within(payment).getByText('Buyer reported escrow initiated')).toBeTruthy()
    expect(payment.textContent).toContain('Reported by you')
    expect(payment.textContent).toContain('not verified by BROKA')
    expect(payment.textContent).toContain('reference TX123')
    expect(payment.textContent).toContain('BROKA does not receive, hold, verify or release payments for store orders.')
    expect(document.body.textContent).not.toMatch(/\bBROKA verified\b|\bPayment verified\b|\bSTK\b|\bwallet\b|\bpayouts?\b/i)
  })

  it('names the provider as independent, and opens its own website in a new tab', async () => {
    openOrder(withEscrow)
    const payment = await screen.findByTestId('payment')
    expect(payment.textContent).toContain('Independent escrow provider - Example Escrow')
    expect(payment.textContent).toContain(providerNotice)
    const site = within(payment).getByRole('link', { name: /official website/ })
    expect(site.getAttribute('href')).toBe('https://escrow.example.co.ke/')
    expect(site.getAttribute('target')).toBe('_blank')
    expect((site.getAttribute('rel') ?? '').split(/\s+/)).toEqual(expect.arrayContaining(['noopener', 'noreferrer', 'nofollow']))
  })

  it("links nowhere when the provider's address is not on its own domain", async () => {
    openOrder(
      confirmed({
        ...withEscrow.payment,
        provider: { ...escrowProvider, url: 'https://escrow.example.co.ke.evil.test/' },
      }),
    )
    const payment = await screen.findByTestId('payment')
    expect(within(payment).queryByRole('link')).toBeNull()
    expect(payment.textContent).toContain(providerNotice)
  })

  it('lets the buyer choose an independent escrow provider, from the directory only', async () => {
    const stub = openOrder(confirmed({ can_choose: true }))
    const payment = await screen.findByTestId('payment')
    // Paying the store directly is where it starts.
    expect((within(payment).getByLabelText(/Pay the store directly/) as HTMLInputElement).checked).toBe(true)
    fireEvent.click(within(payment).getByLabelText(/Use an independent escrow service/))
    expect(payment.textContent).toContain(REQUIRED_NOTICE)
    const save = within(payment).getByRole('button', { name: 'Save how I pay' }) as HTMLButtonElement
    // Escrow, but no provider chosen yet.
    expect(save.disabled).toBe(true)
    fireEvent.click(within(payment).getByLabelText(/Example Escrow/))
    expect(save.disabled).toBe(false)
    fireEvent.click(save)
    await waitFor(() => expect(stub.to('/api/stores/orders/o1/payment-arrangement', 'POST')).toHaveLength(1))
    expect(stub.to('/api/stores/orders/o1/payment-arrangement')[0]!.body).toEqual({
      arrangement: 'independent_escrow',
      provider_id: 'p1',
    })
  })

  it("records the buyer's own report of paying, labelled as theirs, with a warning never to type a PIN", async () => {
    const stub = openOrder(
      confirmed({
        arrangement: 'direct_to_seller',
        arrangement_label: 'Direct payment to the store',
        can_choose: false,
        allowed_reports: ['buyer_reported_payment_sent'],
      }),
    )
    const payment = await screen.findByTestId('payment')
    expect(payment.textContent).toContain('Never type your M-Pesa PIN')
    expect(payment.textContent).toContain('It is your report, not a confirmation from BROKA.')
    fireEvent.change(within(payment).getByLabelText('Payment reference (optional)'), { target: { value: ' QK12AB34 ' } })
    fireEvent.click(within(payment).getByRole('button', { name: 'Report that I paid the store' }))
    await waitFor(() => expect(stub.to('/api/stores/orders/o1/payment-reports', 'POST')).toHaveLength(1))
    expect(stub.to('/api/stores/orders/o1/payment-reports')[0]!.body).toEqual({
      kind: 'buyer_reported_payment_sent',
      reference: 'QK12AB34',
    })
  })
})
