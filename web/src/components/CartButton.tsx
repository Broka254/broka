'use client'

// The cart in the store's header: how many items, and on a wide screen the
// total - one tap opens the cart drawer.
import { cartCount, cartTotal, openCartDrawer, useCart } from '@/lib/cart'
import { formatPrice } from '@/lib/format'

import { Icon } from './Icon'
import styles from './shop.module.css'

export function CartButton({ storeId }: { storeId: string }) {
  const lines = useCart(storeId)
  const n = cartCount(lines)
  return (
    <button
      type="button"
      className={styles.cartButton}
      onClick={openCartDrawer}
      aria-label={n ? `Cart, ${n} item${n === 1 ? '' : 's'}` : 'Cart'}
    >
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
    </button>
  )
}
