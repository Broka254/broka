import { render, screen, within } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import { resetSession } from '@/lib/session-client'
import { json, order, SIGNED_IN, stubFetch } from '@/test/fixtures'

const api = vi.hoisted(() => ({
  getEscrowDirectory: vi.fn().mockResolvedValue({ providers: [], disclaimer: '', notices: [] }),
}))
vi.mock('@/lib/api', () => api)

const { default: OrdersPage } = await import('./page')
const { default: OrderPage } = await import('./[orderId]/page')
const { default: AccountMessagesPage } = await import('../account/messages/page')

beforeEach(() => resetSession())

const accountTabs = () => screen.getByRole('navigation', { name: 'Your account' })

describe("the buyer's account pages", () => {
  it("the orders, from every store, are under BROKA's account header - never one store's", async () => {
    stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/orders?scope=open': json({ items: [], total: 0 }),
    })
    render(<OrdersPage />)
    expect(within(accountTabs()).getByRole('link', { name: 'Orders' }).getAttribute('aria-current')).toBe('page')
    expect(screen.queryByRole('navigation', { name: 'Store sections' })).toBeNull()
    expect(screen.getByRole('main').id).toBe('main-content')
    expect(await screen.findByRole('heading', { name: 'Your orders' })).toBeTruthy()
  })

  it('one order sits inside Orders, and leads to its own store', async () => {
    stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/orders/o1': json(order()),
    })
    render(await OrderPage({ params: Promise.resolve({ orderId: 'o1' }) }))
    expect(within(accountTabs()).getByRole('link', { name: 'Orders' }).getAttribute('aria-current')).toBe('true')
    expect(within(await screen.findByTestId('order-store')).getByRole('link', { name: /Visit the store/ }).getAttribute('href')).toBe(
      '/store/clanix',
    )
  })

  it('the messages from every store are the account\'s Messages', async () => {
    stubFetch({
      '/api/stores/session': json(SIGNED_IN),
      '/api/stores/conversations': json({ conversations: [], partial: false }),
    })
    render(<AccountMessagesPage />)
    expect(within(accountTabs()).getByRole('link', { name: 'Messages' }).getAttribute('aria-current')).toBe('page')
    expect(await screen.findByRole('heading', { name: 'Messages', level: 1 })).toBeTruthy()
  })
})
