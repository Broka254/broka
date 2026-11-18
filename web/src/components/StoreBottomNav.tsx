'use client'

// The store's sections along the bottom of a phone, within thumb reach:
// Home, Shop, Messages, the cart and the buyer's orders - the places the
// row under the header links to on a wide screen, which this stands in for
// (store-nav.module.css shows one or the other, never both). The cart shows
// how many items it holds and opens the cart drawer, as the header's cart
// does. The bar steps out of the way while the buyer types, so it never
// rides up on the keyboard over what they are typing into.
import Link from 'next/link'
import { useEffect, useState } from 'react'

import { cartCount, openCartDrawer, useCart } from '@/lib/cart'
import { currentMark, type StorePage, type StorePaths, type StoreSection } from '@/lib/store-nav'

import { cartLabel } from './CartButton'
import { Icon, type IconName } from './Icon'
import styles from './store-nav.module.css'

const TEXT_INPUT = /^(INPUT|TEXTAREA|SELECT)$/
const NOT_TYPED_INTO = new Set(['checkbox', 'radio', 'button', 'submit', 'reset', 'range', 'color', 'file'])

function takesTyping(el: Element | null): boolean {
  if (!(el instanceof HTMLElement)) return false
  if (el.isContentEditable) return true
  if (!TEXT_INPUT.test(el.tagName)) return false
  return !(el instanceof HTMLInputElement && NOT_TYPED_INTO.has(el.type))
}

/** Whether a text field has focus - on a phone, the keyboard is up. */
function useTyping(): boolean {
  const [typing, setTyping] = useState(false)
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | undefined
    const onIn = (e: FocusEvent) => {
      if (takesTyping(e.target as Element | null)) setTyping(true)
    }
    // Focus moving from one field to the next blurs the first: look once
    // the move is over, not in between.
    const onOut = () => {
      clearTimeout(timer)
      timer = setTimeout(() => setTyping(takesTyping(document.activeElement)), 0)
    }
    document.addEventListener('focusin', onIn)
    document.addEventListener('focusout', onOut)
    return () => {
      clearTimeout(timer)
      document.removeEventListener('focusin', onIn)
      document.removeEventListener('focusout', onOut)
    }
  }, [])
  return typing
}

export function StoreBottomNav({ storeId, paths, page }: { storeId: string; paths: StorePaths; page: StorePage }) {
  const lines = useCart(storeId)
  const n = cartCount(lines)
  const typing = useTyping()

  const section = (key: StoreSection, label: string, icon: IconName, href: string) => (
    <li key={key}>
      <Link href={href} className={styles.tab} aria-current={currentMark(key, page)}>
        <span className={styles.tabIcon}>
          <Icon name={icon} size={22} />
        </span>
        <span>{label}</span>
      </Link>
    </li>
  )

  const cartBody = (
    <>
      <span className={styles.tabIcon}>
        <Icon name="cart" size={22} />
        {n > 0 && (
          <span key={n} className={styles.tabBadge} data-testid="bottom-nav-cart-count">
            {n}
          </span>
        )}
      </span>
      <span>Cart</span>
    </>
  )

  return (
    <nav className={styles.bottomNav} data-away={typing || undefined} aria-label="Store menu">
      <ul className={styles.tabs}>
        {section('home', 'Home', 'home', paths.home)}
        {section('shop', 'Shop', 'grid', paths.shop)}
        {paths.messages && section('messages', 'Messages', 'chat', paths.messages)}
        {paths.cart && (
          <li>
            {page === 'cart' ? (
              // The cart page has no drawer: the tab is the page itself.
              <Link href={paths.cart} className={styles.tab} aria-current="page" aria-label={cartLabel(n)}>
                {cartBody}
              </Link>
            ) : (
              <button type="button" className={styles.tab} onClick={openCartDrawer} aria-label={cartLabel(n)}>
                {cartBody}
              </button>
            )}
          </li>
        )}
        {paths.orders && (
          <li>
            <Link href={paths.orders} className={styles.tab}>
              <span className={styles.tabIcon}>
                <Icon name="receipt" size={22} />
              </span>
              <span>Orders</span>
            </Link>
          </li>
        )}
      </ul>
    </nav>
  )
}
