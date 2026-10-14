import { act, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type { ProductCardData } from './catalogue'
import { ADDED_NOTE_MS, cart, cartCount, cartItemsParam, cartTotal, lineFor, useCart, useLastAdded } from './cart'

const product = (id: string, over: Partial<ProductCardData> = {}): ProductCardData => ({
  id,
  name: `Item ${id}`,
  price: 1000,
  unit: null,
  priceLabel: 'KES 1,000',
  href: `/store/clanix/p/${id}`,
  image: 'https://cdn/x.webp',
  imageSrcSet: null,
  emoji: '📱',
  place: null,
  isAuction: false,
  condition: null,
  maxQuantity: 1,
  ...over,
})

beforeEach(() => cart.reset())
afterEach(() => vi.useRealTimers())

describe('the cart', () => {
  it('adds up to what the listing has, and keeps it in this browser', () => {
    expect(cart.add('s1', lineFor(product('a', { maxQuantity: 2, price: 500 })))).toBe(true)
    expect(cart.add('s1', lineFor(product('a', { maxQuantity: 2, price: 500 })))).toBe(true)
    expect(cart.add('s1', lineFor(product('a', { maxQuantity: 2, price: 500 })))).toBe(false)
    expect(cart.add('s1', lineFor(product('b')), 5)).toBe(true)
    const lines = cart.lines('s1')
    expect(lines.map((l) => [l.id, l.qty])).toEqual([
      ['a', 2],
      ['b', 1],
    ])
    expect(cartCount(lines)).toBe(3)
    expect(cartTotal(lines)).toBe(2000)
    expect(cartItemsParam(lines)).toBe('a:2,b:1')

    // Another page view reads it back; another store has its own.
    cart.reset()
    expect(cart.lines('s1').map((l) => l.id)).toEqual(['a', 'b'])
    expect(cart.lines('s2')).toEqual([])
  })

  it('changes and removes lines', () => {
    cart.add('s1', lineFor(product('a', { maxQuantity: 5 })))
    cart.setQty('s1', 'a', 9)
    expect(cart.lines('s1')[0]!.qty).toBe(5)
    cart.setQty('s1', 'a', 0)
    expect(cart.lines('s1')).toEqual([])
    expect(localStorage.getItem('broka_cart_v1_s1')).toBeNull()
  })

  it('never keeps an inline image or trusts a tampered saved cart', () => {
    expect(lineFor(product('a', { image: 'data:image/png;base64,AAAA' })).image).toBeNull()
    localStorage.setItem(
      'broka_cart_v1_s9',
      JSON.stringify([
        { id: 'ok', name: 'Fine', price: 100, href: '/store/x/p/ok', max: 2, qty: 50 },
        { id: 'evil', name: 'Link', price: 1, href: 'https://evil.example/', max: 1, qty: 1 },
        'junk',
      ]),
    )
    expect(cart.lines('s9').map((l) => [l.id, l.qty])).toEqual([['ok', 2]])
  })

  it('updates components as it changes, and says what was just added', () => {
    vi.useFakeTimers()
    const { result } = renderHook(() => ({ lines: useCart('s1'), added: useLastAdded() }))
    expect(result.current.lines).toEqual([])
    act(() => {
      cart.add('s1', lineFor(product('a')))
    })
    expect(result.current.lines).toHaveLength(1)
    expect(result.current.added?.name).toBe('Item a')
    act(() => {
      vi.advanceTimersByTime(ADDED_NOTE_MS + 10)
    })
    expect(result.current.added).toBeNull()
  })
})
