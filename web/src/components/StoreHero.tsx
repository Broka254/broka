import type { StoreView } from '@/lib/storefront'

import { ShareButtons } from './ShareButtons'
import { TrustChips } from './TrustChips'
import styles from './store.module.css'

export function StoreHero({ view }: { view: StoreView }) {
  const { store } = view
  const subtitle = [store.category, view.place].filter(Boolean).join(' · ')
  return (
    <section className={styles.hero} aria-labelledby="store-name">
      <div className={styles.cover} style={view.cover ? undefined : { background: `linear-gradient(135deg, ${view.gradient.join(', ')})` }}>
        {view.cover && (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={view.cover.src} srcSet={view.cover.srcSet ?? undefined} sizes="100vw" alt="" fetchPriority="high" />
        )}
      </div>
      <div className={styles.identity}>
        <div className={styles.logo}>
          {view.logo ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={view.logo} alt={`${store.name} logo`} />
          ) : (
            <span aria-hidden="true">{view.initial}</span>
          )}
        </div>
        <div>
          <h1 id="store-name" className={styles.name}>
            {store.name}
          </h1>
          {subtitle && <p className={styles.place}>{subtitle}</p>}
        </div>
      </div>
      <div className={styles.about}>
        {store.owner && (
          <TrustChips
            verified={store.owner.verified}
            completedDeals={store.owner.completed_deals}
            rating={store.owner.rating}
            memberSince={store.owner.member_since}
          />
        )}
        {view.description && <p className={styles.description}>{view.description}</p>}
        {store.business_email && store.business_email_verified && (
          <a className={styles.email} href={`mailto:${store.business_email}`}>
            ✉ {store.business_email}
          </a>
        )}
        <div className={styles.actions}>
          <ShareButtons storeId={store.id} url={view.url} title={store.name} />
        </div>
      </div>
      {!store.is_active && (
        <p className={styles.paused} role="status">
          ⏸ {store.name} is taking a break. Its products will be back soon.
        </p>
      )}
    </section>
  )
}
