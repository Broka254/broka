// The top of the store: its name, large, over moving colour - aurora
// light in the store's category colours and BROKA's violet and blue, orbit
// rings, stars, and a shimmer running through the letters - with, on a wide
// screen, its first products fanned out beside it. No logo square: the old
// rounded square read as a profile picture, and its initial as a
// placeholder. Under the name: what and where, whether the owner is online,
// the seller's record, and More for everything else (the Store details
// page). The page's only animation is here, and it stops for anyone who
// asked for less motion.
import Link from 'next/link'

import type { ProductCardData } from '@/lib/catalogue'
import { placeLine, plural } from '@/lib/format'
import { storeDetailsPath } from '@/lib/links'
import type { StoreView } from '@/lib/storefront'

import { Icon } from './Icon'
import styles from './shop.module.css'

export function StoreHero({ view, showcase = [] }: { view: StoreView; showcase?: ProductCardData[] }) {
  const { store } = view
  const owner = store.owner
  const subtitle = [store.category, placeLine(store.subcounty, store.county)].filter(Boolean).join(' · ')
  const deals = owner?.completed_deals ?? 0
  // A rating only means something once there are deals behind it.
  const rating = deals > 0 && owner?.rating != null ? owner.rating.toFixed(1) : null
  const pictures = showcase.filter((p) => p.image).slice(0, 3)
  const [c1, c2] = view.gradient

  return (
    <section
      className={styles.hero}
      aria-labelledby="store-name"
      style={{ ['--hero-a' as string]: c1, ['--hero-b' as string]: c2 ?? c1 }}
    >
      <div className={styles.heroArt} aria-hidden="true">
        <span className={`${styles.blob} ${styles.blob1}`} />
        <span className={`${styles.blob} ${styles.blob2}`} />
        <span className={`${styles.blob} ${styles.blob3}`} />
        <span className={`${styles.blob} ${styles.blob4}`} />
        <span className={`${styles.orbit} ${styles.orbit1}`} />
        <span className={`${styles.orbit} ${styles.orbit2}`} />
        <span className={styles.stars} />
        <span className={styles.sheen} />
      </div>

      <div className={styles.heroBody}>
        <div className={styles.heroChips}>
          {owner?.verified ? (
            <span className={styles.glassChip}>
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

        <h1 id="store-name" className={styles.heroName} data-text={store.name}>
          {store.name}
        </h1>
        {subtitle && <p className={styles.heroPlace}>{subtitle}</p>}

        <div className={styles.heroFoot}>
          <ul className={styles.heroFacts}>
            <li className={styles.glassChip}>
              <Icon name="star" size={15} className={styles.starIcon} />
              {rating ?? 'New seller'}
            </li>
            <li className={styles.glassChip}>
              <Icon name="handshake" size={15} className={styles.dealIcon} />
              {plural(deals, 'deal')}
            </li>
            <li className={`${styles.glassChip} ${styles.factProducts}`}>
              <Icon name="bag" size={15} className={styles.bagIcon} />
              {plural(store.listing_count, 'product')}
            </li>
          </ul>
          <Link href={storeDetailsPath(store.slug)} className={styles.moreWidget}>
            <Icon name="grid" size={16} />
            <span>More</span>
            <Icon name="chevron" size={16} />
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
