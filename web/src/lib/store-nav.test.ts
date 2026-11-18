import { describe, expect, it } from 'vitest'

import { currentMark, sectionOf, storePaths } from './store-nav'

describe("a store's sections", () => {
  it('links every section to its page, and the orders to the buyer\'s account', () => {
    expect(storePaths({ slug: 'clanix', is_active: true, orders_enabled: true })).toEqual({
      home: '/store/clanix',
      shop: '/store/clanix/shop',
      about: '/store/clanix/about',
      cart: '/store/clanix/cart',
      messages: '/store/clanix/messages',
      orders: '/store/orders',
    })
  })

  it('has no messages or orders without store orders: the store offers the app for those', () => {
    for (const orders_enabled of [false, undefined]) {
      const paths = storePaths({ slug: 'clanix', is_active: true, orders_enabled })
      expect(paths.messages).toBeNull()
      expect(paths.orders).toBeNull()
      expect(paths.cart).toBe('/store/clanix/cart')
    }
  })

  it('a paused store sells nothing and answers no messages, but its orders stay reachable', () => {
    const paths = storePaths({ slug: 'clanix', is_active: false, orders_enabled: true })
    expect(paths.cart).toBeNull()
    expect(paths.messages).toBeNull()
    expect(paths.orders).toBe('/store/orders')
  })

  it('a product is part of the shop: its link is marked "you are in here", not "this page"', () => {
    expect(sectionOf('product')).toBe('shop')
    expect(currentMark('shop', 'product')).toBe('true')
    expect(currentMark('shop', 'shop')).toBe('page')
    expect(currentMark('home', 'product')).toBeUndefined()
  })

  it('marks the messages page as Messages - never as About', () => {
    expect(currentMark('messages', 'messages')).toBe('page')
    expect(currentMark('about', 'messages')).toBeUndefined()
  })
})
