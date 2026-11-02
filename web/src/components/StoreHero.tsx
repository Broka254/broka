// The store's banner card, as the app opens a store: the shop's cover
// photo across the top, its logo and name under it, what and where it
// sells, whether the owner is around, the store's score and the seller's
// record, and the way in - shop the products, or the Store details page
// for everything else. The shop's own photo or none at all: never a
// placeholder picture passed off as the shop's own.
import Link from 'next/link'

import type { ProductCardData } from '@/lib/catalogue'
import { placeLine, plural } from '@/lib/format'
import { asset, storeDetailsPath, storeShopPath } from '@/lib/links'
import type { StoreView } from '@/lib/storefront'

import { Icon } from './Icon'
import styles from './shop.module.css'

export function StoreHero({ view, showcase = [] }: { view: StoreView; showcase?: ProductCardData[] }) {
  const { store } = view
  const owner = store.owner
  const subtitle = [store.category, view.isVirtual ? view.delivery : placeLine(store.subcounty, store.county)]
    .filter(Boolean)
    .join(' · ')
  const deals = owner?.completed_deals ?? 0
  // Buyer reviews, not deals, make a seller average. A seller with a hundred
  // deals and no review has no average, and the legacy 5.0 account default
  // must never stand in for one (backend reviews/stats.py).
  const ownerReviews = owner?.review_count ?? 0
  const sellerRating = ownerReviews > 0 && owner?.rating != null ? owner.rating : null
  // The SHOP's own rating, 0-10, from its reviews, reply speed and tenure
  // (backend stores/rating.py). Shown ahead of the owner's seller rating:
  // a buyer is judging this shop, not the person's whole history. Absent
  // from older API builds, which keeps the seller rating as the fallback.
  const storeRating = store.rating ?? null
  const reviewCount = store.review_count ?? 0
  const pictures = showcase.filter((p) => p.image).slice(0, 3)

  // The score for this shop: the shop's own 0-10 score, labelled, linking
  // to the buyer reviews behind it; then the seller's 1-5 record; then
  // nothing rather than a number nobody earned.
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
      {view.cover && (
        <div className={styles.storeBanner}>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={view.cover.src} srcSet={view.cover.srcSet ?? undefined} alt={`${store.name} storefront`} />
        </div>
      )}
      <div className={styles.storeCardBody}>
        <div className={styles.storeHead}>
          {/* The store's own logo, or BROKA's when it uploaded none - the
              same fallback the app card and Store details wear. */}
          <div className={styles.storeAvatar} data-testid="store-logo">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={view.logo ?? asset('/logo.png')} alt="" />
          </div>
          <div className={styles.storeHeadText}>
            <div className={styles.heroChips}>
              {owner?.verified ? (
                <span className={`${styles.glassChip} ${styles.chipVerified}`}>
                  <Icon name="verified" size={16} className={styles.verified} role="img" aria-label="Verified seller" aria-hidden={false} />
                  Verified store
                </span>
              ) : (
                <span className={styles.glassChip}>
                  <Icon name="store" size={15} />
                  Store on BROKA
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
            <h1 id="store-name" className={styles.storeName}>{store.name}</h1>
            {subtitle && <p className={styles.storePlace}>{subtitle}</p>}
          </div>
        </div>

        <ul className={styles.heroFacts}>
          <li className={styles.fact}>
            <Icon name="star" size={15} className={styles.starIcon} /> {score}
          </li>
          <li className={styles.fact}>
            <Icon name="handshake" size={15} className={styles.dealIcon} /> {plural(deals, 'deal')}
          </li>
          <li className={`${styles.fact} ${styles.factProducts}`}>
            <Icon name="bag" size={15} className={styles.bagIcon} /> {plural(store.listing_count, 'product')}
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
            <Icon name="grid" size={18} />
            <span>Store details</span>
            <Icon name="chevron" size={18} />
          </Link>
        </div>
      </div>

      {pictures.length > 0 && (
        <div className={styles.showcase} aria-hidden="true">
          {pictures.map((p, i) => (
            // eslint-disable-next-line @next/next/no-img-element
            <img key={p.id} src={p.image!} alt="" className={styles[`card${i + 1}` as 'card1']} />
          ))}
        </div>
      )}

      {!store.is_active && (
        <p className={styles.paused} role="status">
          {store.name} is taking a break. Its products will be back soon.
        </p>
      )}
    </section>
  )
}
