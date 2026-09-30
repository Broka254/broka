'use client'

// The cart page: every product, how many, the total - and checkout.
//
// Checkout is in the BROKA app, where every purchase already goes through
// escrow: "Checkout in the app" opens this cart there (a /store/<name>/cart
// link with the products and quantities; the app reads each product again
// and fills its own cart), and each product is agreed with the store and
// paid by M-Pesa. One payment for the whole cart on the web comes with
// orders (STORES_PLAN.md phase 4). The app is on Android: on an iPhone or a
// computer the page says how to finish on an Android phone rather than
// offering a download that can't be installed (STORES_UI_REVIEW.md H3).
import Link from 'next/link'
import { useState, useSyncExternalStore } from 'react'

import { useIsAndroid } from '@/lib/browser'
import { cart, cartCount, cartItemsParam, cartTotal, useCart } from '@/lib/cart'
import { APP_DOWNLOAD_URL } from '@/lib/config'
import { formatPrice, formatUnitPrice } from '@/lib/format'
import { absoluteUrl, androidAppLink } from '@/lib/links'

import { QtyStepper } from './AddToCart'
import { Icon } from './Icon'
import styles from './shop.module.css'

const noSubscription = () => () => {}

function useIsIos(): boolean {
  return useSyncExternalStore(noSubscription, () => /iPhone|iPad|iPod/i.test(navigator.userAgent), () => false)
}

export function CheckoutView({
  storeId,
  storeName,
  storePath,
  cartPath,
  storeUrl,
}: {
  storeId: string
  storeName: string
  storePath: string
  cartPath: string
  storeUrl: string
}) {
  const lines = useCart(storeId)
  const android = useIsAndroid()
  const ios = useIsIos()
  const [copied, setCopied] = useState(false)
  const n = cartCount(lines)
  const total = cartTotal(lines)
  const appCart = androidAppLink(absoluteUrl(`${cartPath}?items=${encodeURIComponent(cartItemsParam(lines))}`))

  if (lines.length === 0) {
    return (
      <div className={`card ${styles.checkoutEmpty}`}>
        <span className={styles.emptyCartIcon}>
          <Icon name="cart" size={38} />
        </span>
        <h1>Your cart is empty</h1>
        <p>Add products from {storeName} and they wait here, in this browser.</p>
        <Link href={storePath} className="button">
          <Icon name="back" size={18} /> Continue shopping
        </Link>
      </div>
    )
  }

  const copyLink = async () => {
    try {
      await navigator.clipboard.writeText(storeUrl)
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    } catch {
      window.prompt('Copy this link', storeUrl)
    }
  }

  return (
    <div className={styles.checkout}>
      <section aria-labelledby="cart-heading" className={styles.checkoutLines}>
        <div className={styles.checkoutHead}>
          <h1 id="cart-heading">
            Your cart <span>({n})</span>
          </h1>
          <button type="button" className={styles.linkButton} onClick={() => cart.clear(storeId)}>
            Empty cart
          </button>
        </div>
        <ul>
          {lines.map((l) => (
            <li key={l.id} className={`card ${styles.checkoutLine}`}>
              <Link href={l.href} className={styles.lineThumb}>
                {l.image ? (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img src={l.image} alt="" loading="lazy" />
                ) : (
                  <span aria-hidden="true">{l.emoji}</span>
                )}
              </Link>
              <div className={styles.lineBody}>
                <div className={styles.lineTop}>
                  <Link href={l.href} className={styles.lineName}>
                    {l.name}
                  </Link>
                  <button type="button" className={styles.iconButton} onClick={() => cart.remove(storeId, l.id)} aria-label={`Remove ${l.name}`}>
                    <Icon name="trash" size={18} />
                  </button>
                </div>
                <p className={styles.lineUnit}>{formatUnitPrice(l.price, l.unit)}</p>
                <div className={styles.lineFoot}>
                  <QtyStepper qty={l.qty} max={l.max} name={l.name} onChange={(q) => cart.setQty(storeId, l.id, q)} />
                  <strong>{formatPrice(l.price * l.qty)}</strong>
                </div>
              </div>
            </li>
          ))}
        </ul>
        <Link href={storePath} className={styles.keepShopping}>
          <Icon name="back" size={16} /> Continue shopping
        </Link>
      </section>

      <aside className={`card ${styles.summary}`} aria-labelledby="summary-heading">
        <h2 id="summary-heading">Order summary</h2>
        <dl>
          <div>
            <dt>Items ({n})</dt>
            <dd>{formatPrice(total)}</dd>
          </div>
          <div>
            <dt>Delivery</dt>
            <dd>Agreed with the store</dd>
          </div>
          <div>
            <dt>Buyer protection</dt>
            <dd className={styles.good}>
              <Icon name="shield" size={15} /> Included
            </dd>
          </div>
          <div className={styles.summaryTotal}>
            <dt>Total</dt>
            <dd data-testid="cart-total">{formatPrice(total)}</dd>
          </div>
        </dl>

        {android ? (
          <a className={`button ${styles.checkoutButton}`} href={appCart}>
            <Icon name="lock" size={18} /> Checkout in the BROKA app
          </a>
        ) : (
          <div className={styles.checkoutElsewhere} role="note">
            <p>
              <strong>Checkout is in the BROKA app for Android.</strong>{' '}
              {ios ? 'Open this store on an Android phone' : 'Open this store on your Android phone'} to pay: your
              money is held safely until you confirm delivery.
            </p>
            <button type="button" className={`button ${styles.checkoutButton}`} onClick={copyLink}>
              <Icon name={copied ? 'check' : 'share'} size={18} /> {copied ? 'Store link copied' : 'Copy the store link'}
            </button>
            {!ios && (
              <a className={styles.getApp} href={APP_DOWNLOAD_URL} rel="nofollow">
                Get the Android app
              </a>
            )}
          </div>
        )}

        <ol className={styles.steps}>
          <li>
            <strong>Your cart opens in the app</strong> with these products and quantities.
          </li>
          <li>
            <strong>Agree each one with the store</strong> in its deal room - price, delivery or pickup.
          </li>
          <li>
            <strong>Pay by M-Pesa.</strong> BROKA holds the money.
          </li>
          <li>
            <strong>Confirm you received it</strong> and the store is paid.
          </li>
        </ol>
      </aside>
    </div>
  )
}
