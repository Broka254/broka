import type { StoreView } from '@/lib/storefront'

import { ShareButtons } from './ShareButtons'
import { TrustChips } from './TrustChips'
import styles from './store.module.css'

/** Who the store is, at a glance: logo, name, what and where, the owner's
 *  record, and sharing. No cover photo behind the name - it fought with the
 *  text and pushed the products down; the shop's photos, and the rest of
 *  what a visitor needs to know, are under "Store details" (StoreDetails). */
export function StoreHero({ view }: { view: StoreView }) {
  const { store } = view
  const subtitle = [store.category, view.place].filter(Boolean).join(' · ')
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
          </h1>
          {subtitle && <p className={styles.place}>{subtitle}</p>}
        </div>
      </div>
      {store.owner && (
        <TrustChips
          verified={store.owner.verified}
          completedDeals={store.owner.completed_deals}
          rating={store.owner.rating}
          memberSince={store.owner.member_since}
        />
      )}
      <div className={styles.actions}>
        <a className={styles.detailsLink} href="#store-details">
          ⓘ Store details
        </a>
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
