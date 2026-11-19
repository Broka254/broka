// A product in the store's catalogue, as a shop shows it: the photo (a
// little zoom on hover) with its condition, the name, the price, and Add
// to cart. The store's location isn't repeated on every card - it's the
// same on all of them (STORES_UI_REVIEW.md M6).
import Link from 'next/link'

import type { ProductCardData } from '@/lib/catalogue'

import { AddToCart } from './AddToCart'
import { Price } from './Price'
import styles from './shop.module.css'

export function ProductCard({ product, storeId }: { product: ProductCardData; storeId: string }) {
  return (
    // data-spot: the pointer's light crosses the card (Spotlight.tsx).
    <article className={styles.product} data-spot>
      <Link href={product.href} className={styles.productLink}>
        <div className={styles.productImage}>
          {product.image ? (
            // Plain <img>: the API already serves exactly-sized WebP images.
            // eslint-disable-next-line @next/next/no-img-element
            <img
              src={product.image}
              srcSet={product.imageSrcSet ?? undefined}
              sizes="(max-width: 640px) 50vw, (max-width: 1024px) 33vw, 260px"
              alt={product.name}
              loading="lazy"
              decoding="async"
            />
          ) : (
            <span className={styles.productEmoji} aria-hidden="true">
              {product.emoji}
            </span>
          )}
          <span className={styles.badges}>
            {product.isAuction && <span className={`${styles.badge} ${styles.badgeAuction}`}>Auction</span>}
            {product.condition && <span className={styles.badge}>{product.condition}</span>}
            {product.endsLabel && <span className={`${styles.badge} ${styles.badgeEnding}`}>{product.endsLabel}</span>}
            {product.availability === 'out_of_stock' && <span className={styles.badge}>Out of stock</span>}
            {product.availability === 'paused' && <span className={styles.badge}>Unavailable for now</span>}
          </span>
        </div>
        <div className={styles.productBody}>
          <p className={styles.productName}>{product.name}</p>
          <p className={styles.productPrice}>
            <Price label={product.priceLabel} />
          </p>
          {product.quantity != null && product.quantity > 0 && (
            <p className={`${styles.stockLine} ${product.quantity > 3 ? styles.stockLineIn : ''}`}>
              {product.quantity <= 3 ? `Only ${product.quantity} left` : 'In stock'}
            </p>
          )}
        </div>
      </Link>
      <div className={styles.productAction}>
        {product.isAuction ? (
          <Link href={product.href} className={styles.viewButton}>
            View auction
          </Link>
        ) : product.availability && product.availability !== 'available' ? (
          <Link href={product.href} className={styles.viewButton}>
            {product.availability === 'out_of_stock' ? 'Out of stock' : 'Unavailable for now'}
          </Link>
        ) : (
          <AddToCart storeId={storeId} product={product} />
        )}
      </div>
    </article>
  )
}
