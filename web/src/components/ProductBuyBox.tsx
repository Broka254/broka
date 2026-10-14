'use client'

// Buying on a product's page, as a shop offers it: how many, Add to cart,
// and Buy now (the cart, straight to checkout). Once it's in the cart the
// box says so and leads there.
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { useState } from 'react'

import { type CartLine, cart, useCart } from '@/lib/cart'

import { QtyStepper } from './AddToCart'
import { Icon } from './Icon'
import styles from './shop.module.css'

export function ProductBuyBox({
  storeId,
  line,
  cartPath,
}: {
  storeId: string
  line: Omit<CartLine, 'qty'>
  cartPath: string
}) {
  const router = useRouter()
  const lines = useCart(storeId)
  const inCart = lines.find((l) => l.id === line.id)?.qty ?? 0
  const [qty, setQty] = useState(1)
  const left = Math.max(0, line.max - inCart)

  return (
    <div className={styles.buyBox}>
      {line.max > 1 && left > 0 && (
        <div className={styles.buyQty}>
          <span>Quantity</span>
          <QtyStepper
            removable={false}
            qty={Math.min(qty, left)}
            max={left}
            name={line.name}
            onChange={(q) => setQty(Math.max(1, q))}
          />
          <small>{line.max} available</small>
        </div>
      )}
      <div className={styles.buyButtons}>
        {left > 0 ? (
          <button type="button" className={`button button--ghost ${styles.buyAdd}`} onClick={() => cart.add(storeId, line, Math.min(qty, left))}>
            <Icon name="cart" size={19} /> Add to cart
          </button>
        ) : (
          <Link href={cartPath} className={`button button--ghost ${styles.buyAdd}`}>
            <Icon name="check" size={19} /> In your cart
          </Link>
        )}
        <button
          type="button"
          className={`button ${styles.buyNow}`}
          onClick={() => {
            if (!inCart) cart.add(storeId, line, qty)
            router.push(cartPath)
          }}
        >
          Buy now
        </button>
      </div>
      {inCart > 0 && (
        <p className={styles.inCartNote}>
          <Icon name="check" size={16} /> {inCart} in your cart · <Link href={cartPath}>View cart</Link>
        </p>
      )}
    </div>
  )
}
