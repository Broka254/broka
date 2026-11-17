import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import { cart } from '@/lib/cart'
import { resetSession } from '@/lib/session-client'
import { json, SIGNED_IN, stubFetch } from '@/test/fixtures'

import { CheckoutView } from './CheckoutView'
import { SignInPanel } from './SignInPanel'

const push = vi.fn()
vi.mock('next/navigation', () => ({ useRouter: () => ({ push }) }))

// Before each, not after: a test's components are still mounted when it ends.
beforeEach(() => {
  cart.reset()
  resetSession()
  push.mockReset()
})

const ANDROID_UA = 'Mozilla/5.0 (Linux; Android 14; SM-A145F) AppleWebKit/537.36 Chrome/124 Mobile Safari/537.36'
const IPHONE_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1'
const IPAD_UA = 'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1'
const DESKTOP_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36'

function userAgent(ua: string) {
  vi.spyOn(window.navigator, 'userAgent', 'get').mockReturnValue(ua)
}

const store = {
  storeId: 's1',
  storeName: 'Clanix',
  storePath: '/store/clanix',
  cartPath: '/store/clanix/cart',
  storeUrl: 'https://broka.co.ke/store/clanix',
}
const on = { enabled: true, accepting: true }
const line = { id: 'p1', name: 'Samsung A15', price: 15000, unit: null, image: null, emoji: '📱', href: '/store/clanix/p/p1', max: 3 }

describe('SignInPanel', () => {
  const type = (label: string | RegExp, value: string) =>
    fireEvent.change(screen.getByLabelText(label), { target: { value } })
  const click = (name: string) => fireEvent.click(screen.getByRole('button', { name }))

  it('signs an existing account in with a code, with no password and no app', async () => {
    const stub = stubFetch({
      '/api/stores/session/code': json({ phone: '+254712345678', account_exists: true, expires_in_seconds: 300 }),
      '/api/stores/session/verify': json(SIGNED_IN),
    })
    const onSignedIn = vi.fn()
    render(<SignInPanel onSignedIn={onSignedIn} />)

    expect((screen.getByRole('button', { name: 'Send me a code' }) as HTMLButtonElement).disabled).toBe(true)
    type('Phone number', '0712345678')
    click('Send me a code')
    expect(await screen.findByLabelText('Code')).toBeTruthy()
    expect(stub.to('/api/stores/session/code')[0]!.body).toEqual({ phone: '0712345678' })
    expect(stub.to('/api/stores/session/code')[0]!.headers['x-broka-web']).toBe('1')
    // Not a test environment: no code on the screen.
    expect(screen.queryByTestId('dev-code')).toBeNull()

    type('Code', '123456')
    click('Continue')
    await waitFor(() => expect(onSignedIn).toHaveBeenCalledWith(SIGNED_IN.user))
    expect(stub.to('/api/stores/session/verify')[0]!.body).toEqual({ phone: '0712345678', code: '123456' })
  })

  it('shows the code only when the API sends one - a test environment', async () => {
    stubFetch({ '/api/stores/session/code': json({ account_exists: false, debug_code: '482913' }) })
    render(<SignInPanel />)
    type('Phone number', '0712345678')
    click('Send me a code')
    expect((await screen.findByTestId('dev-code')).textContent).toContain('482913')
  })

  it('a wrong code says so and signs nobody in', async () => {
    stubFetch({
      '/api/stores/session/code': json({ account_exists: true }),
      '/api/stores/session/verify': json({ error: { code: 'HTTP_400', message: 'Invalid or expired code' } }, 400),
    })
    const onSignedIn = vi.fn()
    render(<SignInPanel onSignedIn={onSignedIn} />)
    type('Phone number', '0712345678')
    click('Send me a code')
    await screen.findByLabelText('Code')
    type('Code', '000000')
    click('Continue')
    expect((await screen.findByRole('alert')).textContent).toBe('Invalid or expired code')
    expect(onSignedIn).not.toHaveBeenCalled()
  })

  it('a new number gives a name and accepts the Terms before an account exists - nothing ticked for them', async () => {
    const stub = stubFetch({
      '/api/stores/session/code': json({ account_exists: false }),
      '/api/stores/session/verify': json({ signed_in: false, needs_account: true }),
      '/api/stores/session/account': json(SIGNED_IN, 201),
    })
    const onSignedIn = vi.fn()
    render(<SignInPanel onSignedIn={onSignedIn} />)
    type('Phone number', '0722000111')
    click('Send me a code')
    await screen.findByLabelText('Code')
    type('Code', '123456')
    click('Continue')
    expect(await screen.findByRole('heading', { name: 'Create your BROKA account' })).toBeTruthy()

    // The documents are linked, and open in their own tab so the form stays.
    const terms = screen.getByRole('link', { name: 'Terms of Use and Service' })
    expect(terms.getAttribute('href')).toBe('/store/legal/terms')
    expect(terms.getAttribute('target')).toBe('_blank')
    expect(screen.getByRole('link', { name: 'Privacy Policy' }).getAttribute('href')).toBe('/store/legal/privacy')
    for (const box of screen.getAllByRole('checkbox')) expect((box as HTMLInputElement).checked).toBe(false)

    // A name alone is not enough.
    type('Your name', 'Amina Wanjiru')
    click('Create account and continue')
    expect((await screen.findByRole('alert')).textContent).toBe('Tick all three boxes to create your account.')
    expect(stub.to('/api/stores/session/account')).toHaveLength(0)

    fireEvent.click(screen.getByLabelText('I am at least 18 years old.'))
    fireEvent.click(screen.getByLabelText(/I agree to BROKA/))
    fireEvent.click(screen.getByLabelText(/I have read BROKA/))
    click('Create account and continue')
    await waitFor(() => expect(onSignedIn).toHaveBeenCalledWith(SIGNED_IN.user))
    expect(stub.to('/api/stores/session/account')[0]!.body).toEqual({
      name: 'Amina Wanjiru',
      age_confirmed: true,
      terms_accepted: true,
      privacy_acknowledged: true,
    })
  })

  it('when the proof of the phone has lapsed, goes back to the number instead of failing quietly', async () => {
    stubFetch({
      '/api/stores/session/code': json({ account_exists: false }),
      '/api/stores/session/verify': json({ signed_in: false, needs_account: true }),
      '/api/stores/session/account': json(
        { error: { code: 'PHONE_NOT_VERIFIED', message: 'Verify your phone number again to continue.' } },
        400,
      ),
    })
    render(<SignInPanel />)
    type('Phone number', '0722000111')
    click('Send me a code')
    await screen.findByLabelText('Code')
    type('Code', '123456')
    click('Continue')
    await screen.findByLabelText('Your name')
    type('Your name', 'Amina Wanjiru')
    fireEvent.click(screen.getByLabelText('I am at least 18 years old.'))
    fireEvent.click(screen.getByLabelText(/I agree to BROKA/))
    fireEvent.click(screen.getByLabelText(/I have read BROKA/))
    click('Create account and continue')
    expect((await screen.findByRole('alert')).textContent).toBe('Verify your phone number again to continue.')
    expect(screen.getByLabelText('Phone number')).toBeTruthy()
  })
})

describe('checkout with store orders on', () => {
  describe.each([
    ['an Android phone', ANDROID_UA],
    ['an iPhone', IPHONE_UA],
    ['an iPad', IPAD_UA],
    ['a computer', DESKTOP_UA],
  ])('on %s', (_device: string, ua: string) => {
    const noAppTalk = () => {
      const text = document.body.textContent ?? ''
      expect(text).not.toMatch(/Android/)
      expect(text).not.toContain('Agree with the store in the BROKA app')
      expect(text).not.toContain('Get the Android app')
      expect(screen.queryByText('Copy the store link')).toBeNull()
    }

    it('asks for a phone code to sign in, and never to install or open the app', async () => {
      userAgent(ua)
      stubFetch({ '/api/stores/session': json({ signed_in: false }) })
      cart.add('s1', line, 2)
      render(<CheckoutView {...store} ordering={on} />)
      expect(await screen.findByTestId('sign-in')).toBeTruthy()
      noAppTalk()
      // The cart is as the buyer left it.
      expect(screen.getByTestId('cart-total').textContent).toBe('KES 30,000')
    })

    it('shows the order form once signed in', async () => {
      userAgent(ua)
      stubFetch({ '/api/stores/session': json(SIGNED_IN) })
      cart.add('s1', line, 2)
      render(<CheckoutView {...store} ordering={on} />)
      expect(await screen.findByTestId('web-checkout')).toBeTruthy()
      expect(screen.getByTestId('send-order').textContent).toBe('Send order request')
      noAppTalk()
    })
  })

  it('says plainly what happens next, and that BROKA takes no payment', async () => {
    stubFetch({ '/api/stores/session': json(SIGNED_IN) })
    cart.add('s1', line)
    render(<CheckoutView {...store} ordering={on} />)
    const form = await screen.findByTestId('web-checkout')
    expect(form.textContent).toContain('BROKA does not take or hold the payment')
    expect(form.textContent).toContain("Sending this doesn't pay for anything or commit you")
    expect(screen.getByTestId('confirm-note').textContent).toContain('You see the final total and confirm it yourself.')
  })

  it('sends products and quantities only, with one key for the attempt, and takes the buyer to the order', async () => {
    const stub = stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/s1/orders': json({ id: 'o9' }, 201),
    })
    cart.add('s1', line, 2)
    render(<CheckoutView {...store} ordering={on} />)
    fireEvent.change(await screen.findByLabelText('Delivery address'), { target: { value: 'Kilimani, opposite Yaya Centre' } })
    fireEvent.click(screen.getByTestId('send-order'))

    await waitFor(() => expect(push).toHaveBeenCalledWith('/store/orders/o9'))
    const sent = stub.to('/api/stores/s1/orders', 'POST')
    expect(sent).toHaveLength(1)
    expect(sent[0]!.headers['x-broka-web']).toBe('1')
    expect(sent[0]!.headers['x-idempotency-key']).toMatch(/^[A-Za-z0-9_-]{8,64}$/)
    expect(sent[0]!.body).toEqual({
      items: [{ listing_id: 'p1', quantity: 2 }],
      fulfilment: 'delivery',
      delivery_address: 'Kilimani, opposite Yaya Centre',
      contact_phone: '+254712345678',
    })
    // A price or a total is the API's to work out, never the browser's.
    expect(JSON.stringify(sent[0]!.body)).not.toMatch(/price|total/i)
    // The cart has become an order.
    expect(cart.lines('s1')).toEqual([])
  })

  it('a double tap sends one order request', async () => {
    let release!: () => void
    const gate = new Promise<void>((resolve) => {
      release = resolve
    })
    const stub = stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/s1/orders': async () => {
        await gate
        return json({ id: 'o9' }, 201)
      },
    })
    cart.add('s1', line)
    render(<CheckoutView {...store} ordering={on} />)
    fireEvent.click(await screen.findByLabelText(/Collect from the store/))
    const send = screen.getByTestId('send-order')
    fireEvent.click(send)
    fireEvent.click(send)
    fireEvent.submit(screen.getByTestId('web-checkout'))
    release()
    await waitFor(() => expect(push).toHaveBeenCalledTimes(1))
    expect(stub.to('/api/stores/s1/orders', 'POST')).toHaveLength(1)
  })

  it('delivery needs an address, and nothing is sent without one', async () => {
    const stub = stubFetch({ '/api/stores/session': json(SIGNED_IN) })
    cart.add('s1', line)
    render(<CheckoutView {...store} ordering={on} />)
    fireEvent.click(await screen.findByTestId('send-order'))
    expect((await screen.findByTestId('checkout-error')).textContent).toContain('Add a delivery address')
    expect(stub.to('/api/stores/s1/orders')).toHaveLength(0)
  })

  it('collection needs no address, and the buyer can give a different phone number', async () => {
    const stub = stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/s1/orders': json({ id: 'o9' }, 201),
    })
    cart.add('s1', line)
    render(<CheckoutView {...store} ordering={on} />)
    fireEvent.click(await screen.findByLabelText(/Collect from the store/))
    expect(screen.queryByLabelText('Delivery address')).toBeNull()
    const phone = screen.getByLabelText('Phone the store can reach you on') as HTMLInputElement
    // Until they type, it is the number on their account.
    expect(phone.value).toBe('+254712345678')
    fireEvent.change(phone, { target: { value: '0722000111' } })
    fireEvent.change(screen.getByLabelText('Anything the store should know? (optional)'), { target: { value: 'After 5pm' } })
    fireEvent.click(screen.getByTestId('send-order'))
    await waitFor(() => expect(push).toHaveBeenCalled())
    expect(stub.to('/api/stores/s1/orders')[0]!.body).toEqual({
      items: [{ listing_id: 'p1', quantity: 1 }],
      fulfilment: 'collection',
      contact_phone: '0722000111',
      note: 'After 5pm',
    })
  })

  it('credits the campaign link that brought the buyer, if they came by one', async () => {
    const stub = stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/s1/orders': json({ id: 'o9' }, 201),
    })
    localStorage.setItem('broka_attr_s1', JSON.stringify({ via: 'tiktok', c: 'krafty-token-1', at: Date.now() }))
    cart.add('s1', line)
    render(<CheckoutView {...store} ordering={on} />)
    fireEvent.click(await screen.findByLabelText(/Collect from the store/))
    fireEvent.click(screen.getByTestId('send-order'))
    await waitFor(() => expect(push).toHaveBeenCalled())
    expect(stub.to('/api/stores/s1/orders')[0]!.body).toMatchObject({ via: 'tiktok', campaign: 'krafty-token-1' })
  })

  it('ignores a campaign link from long ago', async () => {
    const stub = stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/s1/orders': json({ id: 'o9' }, 201),
    })
    const eightDaysAgo = Date.now() - 8 * 86_400_000
    localStorage.setItem('broka_attr_s1', JSON.stringify({ via: 'tiktok', c: 'krafty-token-1', at: eightDaysAgo }))
    cart.add('s1', line)
    render(<CheckoutView {...store} ordering={on} />)
    fireEvent.click(await screen.findByLabelText(/Collect from the store/))
    fireEvent.click(screen.getByTestId('send-order'))
    await waitFor(() => expect(push).toHaveBeenCalled())
    expect(stub.to('/api/stores/s1/orders')[0]!.body).not.toHaveProperty('campaign')
  })

  it("shows why the store refused, with the product's name, and keeps the cart", async () => {
    stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/s1/orders': json(
        { error: { code: 'ORDER_ITEM_OUT_OF_STOCK', message: 'Only 1 left.', listing_id: 'p1' } },
        409,
      ),
    })
    cart.add('s1', line, 2)
    render(<CheckoutView {...store} ordering={on} />)
    fireEvent.click(await screen.findByLabelText(/Collect from the store/))
    fireEvent.click(screen.getByTestId('send-order'))
    expect((await screen.findByTestId('checkout-error')).textContent).toBe('Samsung A15: Only 1 left.')
    expect(push).not.toHaveBeenCalled()
    expect(cart.lines('s1')).toHaveLength(1)
    // The buyer can fix the cart and send again.
    expect((screen.getByTestId('send-order') as HTMLButtonElement).disabled).toBe(false)
  })

  it('a retry after a dropped connection carries the same key, so it can only ever make one order', async () => {
    let attempt = 0
    const stub = stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/s1/orders': () =>
        ++attempt === 1
          ? json({ error: { code: 'API_UNREACHABLE', message: "Couldn't reach BROKA." } }, 503)
          : json({ id: 'o9' }, 201),
    })
    cart.add('s1', line)
    render(<CheckoutView {...store} ordering={on} />)
    fireEvent.click(await screen.findByLabelText(/Collect from the store/))
    fireEvent.click(screen.getByTestId('send-order'))
    expect((await screen.findByTestId('checkout-error')).textContent).toBe("Couldn't reach BROKA.")
    fireEvent.click(screen.getByTestId('send-order'))
    await waitFor(() => expect(push).toHaveBeenCalledWith('/store/orders/o9'))
    const keys = stub.to('/api/stores/s1/orders', 'POST').map((c) => c.headers['x-idempotency-key'])
    expect(keys).toHaveLength(2)
    expect(keys[0]).toBeTruthy()
    expect(keys[1]).toBe(keys[0])
  })

  it('keeps what the buyer typed when the page is reloaded', async () => {
    stubFetch({ '/api/stores/session': json(SIGNED_IN) })
    cart.add('s1', line)
    const first = render(<CheckoutView {...store} ordering={on} />)
    fireEvent.change(await screen.findByLabelText('Delivery address'), { target: { value: 'Westlands, Sarit Centre' } })
    fireEvent.change(screen.getByLabelText('Anything the store should know? (optional)'), { target: { value: 'Call at the gate' } })
    first.unmount()

    render(<CheckoutView {...store} ordering={on} />)
    expect(((await screen.findByLabelText('Delivery address')) as HTMLTextAreaElement).value).toBe('Westlands, Sarit Centre')
    expect((screen.getByLabelText('Anything the store should know? (optional)') as HTMLTextAreaElement).value).toBe('Call at the gate')
  })

  it("a store that paused orders says so, shows the owner's note, and keeps the cart", async () => {
    stubFetch({ '/api/stores/session': json(SIGNED_IN) })
    cart.add('s1', line)
    render(<CheckoutView {...store} ordering={{ enabled: true, accepting: false, pauseNote: 'Back on Monday.' }} />)
    const note = await screen.findByTestId('orders-paused')
    expect(note.textContent).toContain("Clanix isn't taking new orders right now.")
    expect(note.textContent).toContain('Back on Monday.')
    expect(screen.queryByTestId('send-order')).toBeNull()
    expect(cart.lines('s1')).toHaveLength(1)
  })

  it('with store orders off the page is the app handoff it always was, and asks for no session', () => {
    userAgent(IPHONE_UA)
    const stub = stubFetch({})
    cart.add('s1', line)
    render(<CheckoutView {...store} ordering={{ enabled: false, accepting: true }} />)
    expect(screen.getByText('Deals are agreed in the BROKA app for Android.')).toBeTruthy()
    expect(screen.getByText('Copy the store link')).toBeTruthy()
    expect(screen.queryByTestId('web-checkout')).toBeNull()
    expect(screen.queryByTestId('sign-in')).toBeNull()
    expect(stub.fn).not.toHaveBeenCalled()
  })
})
