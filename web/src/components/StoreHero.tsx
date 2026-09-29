import { placeLine } from '@/lib/format'
import { storeDetailsPath } from '@/lib/links'
import type { StoreView } from '@/lib/storefront'

import { ShareButtons } from './ShareButtons'
import styles from './store.module.css'

/** Who the store is, at a glance: logo, name (with a tick for a verified
 *  seller), what and where, "More details", and sharing. Nothing else: no
 *  cover photo behind the name, and no row of record chips - the seller's
 *  deals, rating and year joined, and the shop's photos, are on the Store
 *  details page (/store/<name>/about). */
export function StoreHero({ view }: { view: StoreView }) {
  const { store } = view
  // The area, as in the app; the landmark is on the Store details page. With
  // it the line wrapped onto a second row on a phone.
  const subtitle = [store.category, placeLine(store.subcounty, store.county)].filter(Boolean).join(' · ')
  return (
    <section className={styles.hero} aria-labelledby="store-name">
      <div className={styles.identity}>
        <div className={styles.logo} style={{ boxShadow: `0 10px 34px ${view.gradient[0]}66` }}>
          {view.logo ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={view.logo} alt={`${store.name} logo`} />
          ) : (
            <span aria-hidden="true">{view.initial}</span>
          )}
        </div>
        <div className={styles.identityText}>
          <h1 id="store-name" className={styles.name}>
            {store.name}
            {store.owner?.verified && (
              <span className={styles.verifiedTick} role="img" aria-label="Verified seller" title="Verified seller">
                ✓
              </span>
            )}
          </h1>
          {subtitle && <p className={styles.place}>{subtitle}</p>}
          <a className={styles.moreDetails} href={storeDetailsPath(store.slug)}>
            ⓘ More details ›
          </a>
        </div>
      </div>
      <div className={styles.actions}>
        <ShareButtons storeId={store.id} url={view.url} title={store.name} />
      </div>
      {!store.is_active && (
        <p className={styles.paused} role="status">
          ⏸ {store.name} is taking a break. Its products will be back soon.
        </p>
      )}
    </section>
  )
}
