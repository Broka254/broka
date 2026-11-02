// The store's cover-led opening card: its own sign and name, what and where
// it sells, a compact trust row, then the two useful next actions.
import Link from 'next/link'

import { categoryArtPath } from '@/lib/category-art'
import { placeLine, plural } from '@/lib/format'
import { asset, storeDetailsPath, storeShopPath } from '@/lib/links'
import type { StoreView } from '@/lib/storefront'

import { Icon } from './Icon'
import styles from './shop.module.css'

export function StoreHero({ view }: { view: StoreView }) {
  const { store } = view
  const owner = store.owner
  const subtitle = [store.category, view.isVirtual ? view.delivery : placeLine(store.subcounty, store.county)]
    .filter(Boolean)
    .join(' · ')
  const deals = owner?.completed_deals ?? 0
  const ownerReviews = owner?.review_count ?? 0
  const sellerRating = ownerReviews > 0 && owner?.rating != null ? owner.rating : null
  const storeRating = store.rating ?? null
  const reviewCount = store.review_count ?? 0
  const fallbackArt = categoryArtPath(store.category)

  const score = storeRating != null ? (
    <Link
      href={`${storeDetailsPath(store.slug)}#reviews`}
      className={styles.factLink}
      aria-label={`Store score ${storeRating.toFixed(1)} out of 10${
        reviewCount > 0 ? `, from ${plural(reviewCount, 'review')}` : ''
      }`}
    >
      <span>{storeRating.toFixed(1)}/10</span>
      {reviewCount > 0 && <span className={styles.factMuted}> ({reviewCount})</span>}
    </Link>
  ) : sellerRating != null ? (
    <span aria-label={`Seller rating ${sellerRating.toFixed(1)} out of 5, from ${plural(ownerReviews, 'review')}`}>
      <span>{sellerRating.toFixed(1)}/5</span>
      <span className={styles.factMuted}> ({ownerReviews})</span>
    </span>
  ) : (
    'No reviews yet'
  )

  return (
    <section className={styles.storeCard} aria-labelledby="store-name">
      <div className={styles.storeBanner} aria-hidden={!view.cover}>
        {view.cover ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={view.cover.src} srcSet={view.cover.srcSet ?? undefined} alt={`${store.name} storefront`} />
        ) : fallbackArt ? (
          // Match the app: category artwork is the fallback, not a generic BROKA promo.
          // eslint-disable-next-line @next/next/no-img-element
          <img src={fallbackArt} alt="" />
        ) : null}
      </div>
      <div className={styles.storeCardBody}>
        <div className={styles.storeHead}>
          <div className={styles.storeAvatar} data-testid="store-logo">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={view.logo ?? asset('/logo.png')} alt="" />
          </div>
          <div className={styles.storeHeadText}>
            <h1 id="store-name" className={styles.storeName}>{store.name}</h1>
            {subtitle && <p className={styles.storePlace}>{subtitle}</p>}
          </div>
        </div>

        <div className={styles.heroChips} aria-label="Store status">
          {owner?.verified && (
            <span className={`${styles.glassChip} ${styles.chipVerified}`}>
              <Icon name="verified" size={15} className={styles.verified} role="img" aria-label="Verified seller" aria-hidden={false} />
              Verified store
            </span>
          )}
          {owner?.online ? (
            <span className={`${styles.glassChip} ${styles.online}`} data-testid="presence">
              <span className={styles.liveDot} /> Online now
            </span>
          ) : owner?.last_active ? (
            <span className={`${styles.glassChip} ${styles.away}`} data-testid="presence">
              <span className={styles.awayDot} /> {owner.last_active}
            </span>
          ) : null}
        </div>

        <ul className={styles.heroFacts} aria-label="Store information">
          <li className={styles.fact}>
            <Icon name="star" size={14} className={styles.starIcon} /> {score}
          </li>
          <li className={styles.fact}>
            <Icon name="handshake" size={14} className={styles.dealIcon} /> {plural(deals, 'deal')}
          </li>
          <li className={`${styles.fact} ${styles.factProducts}`}>
            <Icon name="bag" size={14} className={styles.bagIcon} /> {plural(store.listing_count, 'product')}
          </li>
          <li className={styles.fact}>
            {store.is_active ? 'Open now' : 'Taking a break'}
          </li>
        </ul>

        <div className={styles.heroCtas}>
          <Link href={storeShopPath(store.slug)} className={`button ${styles.heroShop}`}>
            Shop products
          </Link>
          <Link
            href={storeDetailsPath(store.slug)}
            className={styles.moreWidget}
            aria-label={`Store details for ${store.name}`}
          >
            <Icon name="grid" size={17} />
            <span>Store details</span>
            <Icon name="chevron" size={17} />
          </Link>
        </div>
      </div>
      {!store.is_active && (
        <p className={styles.paused} role="status">
          {store.name} is taking a break. Its products will be back soon.
        </p>
      )}
    </section>
  )
}
