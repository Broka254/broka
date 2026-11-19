'use client'

// On a phone, once the buy box has scrolled away - into the description,
// the escrow services, the seller, more from the store - the product, its
// price and Buy now stay within thumb reach: a bar over the store's bottom
// bar (shop.module.css .stickyBuy; nothing on a wide screen, where the buy
// box stays beside the photos). Buy now does what the buy box's does: puts
// one in the cart if it isn't there, and goes to the cart.
//
// It shows only while the buy box is above the screen and the footer isn't
// on it (so it never covers the page's last lines), and steps away while
// the buyer types, as the bottom bar does. Without IntersectionObserver it
// never shows: the buy box is still there.
import { useRouter } from 'next/navigation'
import { useEffect, useState } from 'react'

import { type CartLine, cart, useCart } from '@/lib/cart'
import { reportCartAdd } from '@/lib/visitor'

import { Price } from './Price'
import { useTyping } from './StoreBottomNav'
import styles from './shop.module.css'

export function ProductStickyBar({
  storeId,
  line,
  cartPath,
  priceLabel,
  watch,
}: {
  storeId: string
  line: Omit<CartLine, 'qty'>
  cartPath: string
  priceLabel: string
  /** The id of the buy box this stands in for. */
  watch: string
}) {
  const router = useRouter()
  const inCart = useCart(storeId).find((l) => l.id === line.id)?.qty ?? 0
  const typing = useTyping()
  const [scrolledPast, setScrolledPast] = useState(false)
  const [footerInView, setFooterInView] = useState(false)

  useEffect(() => {
    if (typeof IntersectionObserver === 'undefined') return
    const box = document.getElementById(watch)
    const footer = document.querySelector('[data-store-footer]')
    const observers: IntersectionObserver[] = []
    if (box) {
      // The root reaches far below the screen, so the box "intersects" it
      // whenever any of it is below the screen's top edge, and stops only
      // once it is entirely above. Against the plain viewport, a jump from
      // below the screen to above it (restored scroll, a fling on a slow
      // phone) is no change at all - not intersecting either way - and the
      // observer would never call.
      // The newest entry, not the first: one call can carry several, oldest first.
      const io = new IntersectionObserver(
        (entries) => {
          const entry = entries[entries.length - 1]
          if (entry) setScrolledPast(!entry.isIntersecting)
        },
        { rootMargin: '0px 0px 100000px 0px' },
      )
      io.observe(box)
      observers.push(io)
    }
    if (footer) {
      const io = new IntersectionObserver((entries) => {
        const entry = entries[entries.length - 1]
        if (entry) setFooterInView(entry.isIntersecting)
      })
      io.observe(footer)
      observers.push(io)
    }
    return () => observers.forEach((o) => o.disconnect())
  }, [watch])

  if (!scrolledPast || footerInView || typing) return null
  return (
    <div className={styles.stickyBuy} role="region" aria-label="Buy this product" data-testid="sticky-buy">
      <span className={styles.stickyThumb}>
        {line.image ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={line.image} alt="" />
        ) : (
          <span aria-hidden="true">{line.emoji}</span>
        )}
      </span>
      <span className={styles.stickyText}>
        <strong>{line.name}</strong>
        <Price label={priceLabel} />
      </span>
      <button
        type="button"
        className={`button ${styles.stickyButton}`}
        onClick={() => {
          if (!inCart && cart.add(storeId, line)) reportCartAdd(storeId, line.id)
          router.push(cartPath)
        }}
      >
        {inCart ? 'View cart' : 'Buy now'}
      </button>
    </div>
  )
}
