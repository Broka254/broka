'use client'

// The cart in the store's header: how many items, and on a wide screen the
// total - one tap opens the cart drawer. On the cart page itself there is
// no drawer to open: there it is the link to the page it is on.
import Link from 'next/link'

import { cartCount, cartTotal, openCartDrawer, useCart } from '@/lib/cart'
import { formatPrice } from '@/lib/format'

import { Icon } from './Icon'
import styles from './shop.module.css'

export function cartLabel(n: number): string {
  return n ? `Cart, ${n} item${n === 1 ? '' : 's'}` : 'Cart'
}

export function CartButton({ storeId, cartPage }: { storeId: string; cartPage?: string }) {
  const lines = useCart(storeId)
  const n = cartCount(lines)
  const body = (
    <>
      <span className={styles.cartIcon}>
        <Icon name="cart" size={22} />
        {n > 0 && (
          // Keyed on the count, so the badge bounces each time it changes.
          <span key={n} className={styles.cartBadge} data-testid="cart-count">
            {n}
          </span>
        )}
      </span>
      <span className={styles.cartButtonText}>{n ? formatPrice(cartTotal(lines)) : 'Cart'}</span>
    </>
  )
  if (cartPage) {
    return (
      <Link href={cartPage} className={styles.cartButton} aria-label={cartLabel(n)} aria-current="page">
        {body}
      </Link>
    )
  }
  return (
    <button type="button" className={styles.cartButton} onClick={openCartDrawer} aria-label={cartLabel(n)}>
      {body}
    </button>
  )
}
