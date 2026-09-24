import Link from 'next/link'

import type { ProductCardData } from '@/lib/catalogue'

import styles from './store.module.css'

export function ProductCard({ product }: { product: ProductCardData }) {
  return (
    <Link href={product.href} className={styles.product}>
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
        {product.isAuction && <span className={styles.badge}>Auction</span>}
      </div>
      <div className={styles.productBody}>
        <p className={styles.productName}>{product.name}</p>
        <p className={styles.productPrice}>{product.priceLabel}</p>
        {product.place && <p className={styles.productPlace}>{product.place}</p>}
      </div>
    </Link>
  )
}
