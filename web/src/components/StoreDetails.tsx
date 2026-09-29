// "Store details": everything a visitor arriving from a shared link needs to
// know about a store before buying from it - which store it is, who runs it
// and their record (deals done, rating, the year they joined), the shop's
// photos, what it says about itself, where it is, how to reach it, and how
// paying through BROKA protects them. The same sections, in the same order,
// as the app's Store details screen (store_details_view.dart).
//
// Its own page (/store/<name>/about), linked from "More details" under the
// store's name, so the store's home is left to its products.
import { monthYearOf, placeLine, plural, yearOf } from '@/lib/format'
import type { StoreView } from '@/lib/storefront'

import styles from './store.module.css'

export function StoreDetails({ view }: { view: StoreView }) {
  const { store } = view
  const owner = store.owner
  const ownerName = owner?.name?.trim() || `The owner of ${store.name}`
  const deals = owner?.completed_deals ?? 0
  // A rating only means something once there are deals behind it.
  const rating = deals > 0 && owner?.rating != null ? owner.rating.toFixed(1) : null
  const since = yearOf(owner?.member_since)
  const opened = monthYearOf(store.created_at)
  const summaryLine = [store.category, placeLine(store.subcounty, store.county)].filter(Boolean).join(' · ')
  const area = placeLine(store.subcounty, store.county) ?? store.country
  const landmark = store.location_description?.trim() || null
  const mapQuery = placeLine(store.location_description, store.subcounty, store.county, store.country)
  const email = store.business_email && store.business_email_verified ? store.business_email : null

  return (
    <div className={styles.storeDetails}>
      <div className={`card ${styles.detailsCard} ${styles.summary}`}>
        <div className={styles.summaryLogo}>
          {view.logo ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={view.logo} alt="" />
          ) : (
            <span aria-hidden="true">{view.initial}</span>
          )}
        </div>
        <div>
          <p className={styles.ownerName}>{store.name}</p>
          {summaryLine && <p className={styles.mutedLine}>{summaryLine}</p>}
          <p className={store.is_active ? styles.statusOpen : styles.statusPaused}>
            {store.is_active ? 'Open' : 'Taking a break'}
          </p>
        </div>
      </div>

      <section aria-labelledby="owner-title">
        <h2 id="owner-title" className={styles.detailsLabel}>
          The seller
        </h2>
        <div className={`card ${styles.detailsCard}`}>
          <div className={styles.owner}>
            <span className={styles.ownerAvatar} aria-hidden="true">
              {(Array.from(ownerName)[0] ?? '?').toUpperCase()}
            </span>
            <div>
              <p className={styles.ownerName}>{ownerName}</p>
              <p className={owner?.verified ? styles.good : styles.mutedLine}>
                {owner?.verified ? '✓ Verified seller' : 'Not verified yet'}
              </p>
            </div>
          </div>
          {/* The seller's record in three numbers, each with what it counts. */}
          <dl className={styles.ownerFacts}>
            <div>
              <dt>{deals === 1 ? 'Deal done' : 'Deals done'}</dt>
              <dd>
                <span className={styles.factIcon} aria-hidden="true">
                  🤝
                </span>
                {deals}
              </dd>
            </div>
            <div>
              <dt>{rating ? 'Rating' : 'No rating yet'}</dt>
              <dd>
                <span className={`${styles.factIcon} ${styles.star}`} aria-hidden="true">
                  ★
                </span>
                {rating ?? 'New'}
              </dd>
            </div>
            <div>
              <dt>On BROKA since</dt>
              <dd>
                {/* Not 📅: most phones draw it as a page reading "July 17",
                    which looks like the date they joined. */}
                <span className={styles.factIcon} aria-hidden="true">
                  🗓️
                </span>
                {since ?? '–'}
              </dd>
            </div>
          </dl>
        </div>
      </section>

      {view.photos.length > 0 && (
        <section aria-labelledby="photos-title">
          <h2 id="photos-title" className={styles.detailsLabel}>
            Photos of the shop
          </h2>
          <ul className={styles.shopPhotos}>
            {view.photos.map((p, i) => (
              <li key={p.src}>
                <a href={p.src} target="_blank" rel="noopener">
                  {/* eslint-disable-next-line @next/next/no-img-element */}
                  <img src={p.thumb} alt={`${store.name}, photo ${i + 1} of ${view.photos.length}`} loading="lazy" />
                </a>
              </li>
            ))}
          </ul>
        </section>
      )}

      {view.description && (
        <section aria-labelledby="about-title">
          <h2 id="about-title" className={styles.detailsLabel}>
            About the store
          </h2>
          <p className={`card ${styles.detailsCard} ${styles.about}`}>{view.description}</p>
        </section>
      )}

      <section aria-labelledby="location-title">
        <h2 id="location-title" className={styles.detailsLabel}>
          Location
        </h2>
        <div className={`card ${styles.detailsCard}`}>
          <p className={landmark ? styles.mutedLine : styles.strongLine}>📍 {area}</p>
          {landmark && <p className={styles.strongLine}>{landmark}</p>}
          {mapQuery && mapQuery !== store.country && (
            <a
              className={styles.detailsAction}
              href={`https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(mapQuery)}`}
              target="_blank"
              rel="noopener"
            >
              Find it on the map
            </a>
          )}
        </div>
      </section>

      <section aria-labelledby="contact-title">
        <h2 id="contact-title" className={styles.detailsLabel}>
          Contact
        </h2>
        <div className={`card ${styles.detailsCard}`}>
          {email && (
            <p className={styles.contactRow}>
              <span className={styles.mutedLine}>Business email</span>
              <a className={styles.detailsAction} href={`mailto:${email}`}>
                {email}
              </a>
            </p>
          )}
          <p className={styles.contactRow}>
            <span className={styles.mutedLine}>Asking about a product</span>
            <span>
              Open the product and make an offer in the BROKA app. Zeno, BROKA&apos;s broker, takes your questions and
              offers to the seller.
            </span>
          </p>
        </div>
      </section>

      <section aria-labelledby="info-title">
        <h2 id="info-title" className={styles.detailsLabel}>
          Store info
        </h2>
        <dl className={`card ${styles.detailsCard} ${styles.infoList}`}>
          {store.category && (
            <div>
              <dt>Sells</dt>
              <dd>{store.category}</dd>
            </div>
          )}
          <div>
            <dt>Store link</dt>
            <dd>
              <a href={view.path}>{view.url.replace(/^https?:\/\//, '')}</a>
            </dd>
          </div>
          <div>
            <dt>Products</dt>
            <dd>{plural(store.listing_count, 'product')} on sale</dd>
          </div>
          {opened && (
            <div>
              <dt>Opened</dt>
              <dd>{opened}</dd>
            </div>
          )}
        </dl>
      </section>

      <section aria-labelledby="safety-title">
        <h2 id="safety-title" className={styles.detailsLabel}>
          Buying safely
        </h2>
        <p className={styles.safety}>
          🛡 Pay only through BROKA. Your money is held in escrow, and the seller is paid once you confirm you have the
          item. Never send money to a seller directly.
        </p>
      </section>
    </div>
  )
}
