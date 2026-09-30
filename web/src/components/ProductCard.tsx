// A product in the store's catalogue, as a shop shows it: the photo (a
// little zoom on hover) with its condition, the name, the price, and Add
// to cart. The store's location isn't repeated on every card - it's the
// same on all of them (STORES_UI_REVIEW.md M6).
import Link from 'next/link'

import type { ProductCardData } from '@/lib/catalogue'

import { AddToCart } from './AddToCart'
import styles from './shop.module.css'

export function ProductCard({ product, storeId }: { product: ProductCardData; storeId: string }) {
  return (
    <article className={styles.product}>
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
          </span>
        </div>
        <div className={styles.productBody}>
          <p className={styles.productName}>{product.name}</p>
          <p className={styles.productPrice}>{product.priceLabel}</p>
        </div>
      </Link>
      <div className={styles.productAction}>
        {product.isAuction ? (
          <Link href={product.href} className={styles.viewButton}>
            View auction
          </Link>
        ) : (
          <AddToCart storeId={storeId} product={product} />
        )}
      </div>
    </article>
  )
}
