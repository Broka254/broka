'use client'

// Add to cart on a product card, and the − n + stepper it becomes once the
// product is in the cart - the way shops show it.
import type { ProductCardData } from '@/lib/catalogue'
import { cart, lineFor, useCart } from '@/lib/cart'

import { Icon } from './Icon'
import styles from './shop.module.css'

export function QtyStepper({
  qty,
  max,
  onChange,
  name,
  compact = false,
  removable = true,
}: {
  qty: number
  max: number
  onChange: (qty: number) => void
  name: string
  compact?: boolean
  /** − at one takes the product out; false stops at one (choosing how many). */
  removable?: boolean
}) {
  const remove = removable && qty <= 1
  return (
    <div className={`${styles.stepper} ${compact ? styles.stepperCompact : ''}`} role="group" aria-label={`Quantity of ${name}`}>
      <button
        type="button"
        onClick={() => onChange(qty - 1)}
        disabled={!removable && qty <= 1}
        aria-label={remove ? `Remove ${name}` : 'One less'}
        className={styles.stepperButton}
      >
        <Icon name={remove ? 'trash' : 'minus'} size={compact ? 16 : 18} />
      </button>
      <output className={styles.stepperQty} aria-live="polite">
        {qty}
      </output>
      <button
        type="button"
        onClick={() => onChange(qty + 1)}
        disabled={qty >= max}
        aria-label={qty >= max ? 'No more available' : 'One more'}
        className={styles.stepperButton}
      >
        <Icon name="plus" size={compact ? 16 : 18} />
      </button>
    </div>
  )
}

export function AddToCart({ storeId, product }: { storeId: string; product: ProductCardData }) {
  const line = lineFor(product)
  const lines = useCart(storeId)
  const qty = lines.find((l) => l.id === line.id)?.qty ?? 0
  if (qty > 0) {
    return (
      <QtyStepper
        compact
        qty={qty}
        max={line.max}
        name={line.name}
        onChange={(q) => cart.setQty(storeId, line.id, q)}
      />
    )
  }
  return (
    <button type="button" className={styles.addToCart} onClick={() => cart.add(storeId, line)}>
      <Icon name="cart" size={17} />
      Add to cart
    </button>
  )
}
