'use client'

// The cart, sliding in from the side: what's in it, how many, the total, and
// the way to checkout. Also the short "Added to cart" note. On a phone the
// cart is the bottom bar's Cart tab, with its count (StoreBottomNav.tsx) -
// the bar that used to appear along the bottom once the cart had something
// in it would now sit on top of that one.
import Link from 'next/link'
import { useEffect, useRef } from 'react'

import { cart, cartCount, cartTotal, closeCartDrawer, openCartDrawer, useCart, useCartDrawer, useLastAdded } from '@/lib/cart'
import { formatPrice, formatUnitPrice } from '@/lib/format'
import { PAY_LINE, SEE_FIRST } from '@/lib/safety'

import { QtyStepper } from './AddToCart'
import { Icon } from './Icon'
import styles from './shop.module.css'

export function CartDrawer({ storeId, storeName, cartPath }: { storeId: string; storeName: string; cartPath: string }) {
  const open = useCartDrawer()
  const lines = useCart(storeId)
  const added = useLastAdded()
  const closeRef = useRef<HTMLButtonElement>(null)
  const n = cartCount(lines)

  useEffect(() => {
    if (!open) return
    const previous = document.activeElement as HTMLElement | null
    closeRef.current?.focus()
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') closeCartDrawer()
    }
    const overflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('keydown', onKey)
      document.body.style.overflow = overflow
      previous?.focus?.()
    }
  }, [open])

  return (
    <>
      {added && !open && (
        <div className={styles.addedNote} role="status">
          <Icon name="check" size={18} />
          <span className={styles.addedName}>Added to cart: {added.name}</span>
          <button type="button" onClick={openCartDrawer}>
            View cart
          </button>
        </div>
      )}

      {open && (
        <div className={styles.drawerScrim} onClick={closeCartDrawer}>
          <aside
            className={styles.drawer}
            role="dialog"
            aria-modal="true"
            aria-labelledby="cart-title"
            onClick={(e) => e.stopPropagation()}
          >
            <header className={styles.drawerHead}>
              <div>
                <h2 id="cart-title">Your cart{n ? ` (${n})` : ''}</h2>
                <p>{storeName}</p>
              </div>
              <button ref={closeRef} type="button" className={styles.iconButton} onClick={closeCartDrawer} aria-label="Close cart">
                <Icon name="close" />
              </button>
            </header>

            {lines.length === 0 ? (
              <div className={styles.drawerEmpty}>
                <span className={styles.emptyCartIcon}>
                  <Icon name="cart" size={34} />
                </span>
                <h3>Your cart is empty</h3>
                <p>Add products from {storeName} and they wait here.</p>
                <button type="button" className="button button--ghost" onClick={closeCartDrawer}>
                  Continue shopping
                </button>
              </div>
            ) : (
              <>
                <ul className={styles.drawerLines}>
                  {lines.map((l) => (
                    <li key={l.id} className={styles.drawerLine}>
                      <Link href={l.href} className={styles.lineThumb} onClick={closeCartDrawer}>
                        {l.image ? (
                          // eslint-disable-next-line @next/next/no-img-element
                          <img src={l.image} alt="" loading="lazy" />
                        ) : (
                          <span aria-hidden="true">{l.emoji}</span>
                        )}
                      </Link>
                      <div className={styles.lineBody}>
                        <Link href={l.href} className={styles.lineName} onClick={closeCartDrawer}>
                          {l.name}
                        </Link>
                        <p className={styles.lineUnit}>{formatUnitPrice(l.price, l.unit)}</p>
                        <div className={styles.lineFoot}>
                          <QtyStepper compact qty={l.qty} max={l.max} name={l.name} onChange={(q) => cart.setQty(storeId, l.id, q)} />
                          <strong>{formatPrice(l.price * l.qty)}</strong>
                        </div>
                      </div>
                    </li>
                  ))}
                </ul>
                <footer className={styles.drawerFoot}>
                  <p className={styles.drawerTotal}>
                    <span>Subtotal</span>
                    <strong>{formatPrice(cartTotal(lines))}</strong>
                  </p>
                  {/* How paying works, said before checkout - not a padlock
                      on the button, which reads as a payment BROKA secures. */}
                  <p className={styles.drawerNote}>
                    <Icon name="info" size={16} /> {PAY_LINE} {SEE_FIRST.lead}
                  </p>
                  <Link href={cartPath} className={`button ${styles.drawerCheckout}`} onClick={closeCartDrawer}>
                    <Icon name="bag" size={18} /> Checkout
                  </Link>
                  <button type="button" className={styles.linkButton} onClick={closeCartDrawer}>
                    Continue shopping
                  </button>
                </footer>
              </>
            )}
          </aside>
        </div>
      )}
    </>
  )
}
