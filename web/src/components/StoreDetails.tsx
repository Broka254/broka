// "Store details": everything a visitor arriving from a shared link needs to
// know about a store before buying from it - the shop's photos, what it
// says about itself, who runs it, where it is, how to reach it, the store's
// basics, and how paying through BROKA protects them. The same sections as
// the app's Store details tab (store_details_view.dart).
//
// Beside the catalogue on wide screens, under it on phones; the hero's
// "Store details" link jumps here either way.
import { monthYearOf, placeLine, plural } from '@/lib/format'
import type { StoreView } from '@/lib/storefront'

import styles from './store.module.css'

export function StoreDetails({ view }: { view: StoreView }) {
  const { store } = view
  const owner = store.owner
  const ownerName = owner?.name?.trim() || `The owner of ${store.name}`
  const deals = owner?.completed_deals ?? 0
  // A rating only means something once there are deals behind it.
  const rating = deals > 0 && owner?.rating != null ? owner.rating.toFixed(1) : null
  const since = monthYearOf(owner?.member_since)
  const opened = monthYearOf(store.created_at)
  const area = placeLine(store.subcounty, store.county) ?? store.country
  const landmark = store.location_description?.trim() || null
  const mapQuery = placeLine(store.location_description, store.subcounty, store.county, store.country)
  const email = store.business_email && store.business_email_verified ? store.business_email : null

  return (
    <aside id="store-details" className={styles.storeDetails} aria-labelledby="store-details-title">
      <h2 id="store-details-title" className={styles.detailsTitle}>
        Store details
      </h2>

      {view.photos.length > 0 && (
        <section aria-label="Photos of the shop">
          <h3 className={styles.detailsLabel}>Photos of the shop</h3>
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
          <h3 id="about-title" className={styles.detailsLabel}>
            About the store
          </h3>
          <p className={`card ${styles.detailsCard} ${styles.about}`}>{view.description}</p>
        </section>
      )}

      <section aria-labelledby="owner-title">
        <h3 id="owner-title" className={styles.detailsLabel}>
          Store owner
        </h3>
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
              {since && <p className={styles.mutedLine}>On BROKA since {since}</p>}
            </div>
          </div>
          <dl className={styles.ownerFacts}>
            <div>
              <dt>{deals === 1 ? 'deal done' : 'deals done'}</dt>
              <dd>{deals}</dd>
            </div>
            <div>
              <dt>rating</dt>
              <dd>
                {rating ? (
                  <>
                    <span className={styles.star} aria-hidden="true">
                      ★{' '}
                    </span>
                    {rating}
                  </>
                ) : (
                  'New'
                )}
              </dd>
            </div>
            <div>
              <dt>{store.listing_count === 1 ? 'product' : 'products'}</dt>
              <dd>{store.listing_count}</dd>
            </div>
          </dl>
        </div>
      </section>

      <section aria-labelledby="location-title">
        <h3 id="location-title" className={styles.detailsLabel}>
          Location
        </h3>
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
        <h3 id="contact-title" className={styles.detailsLabel}>
          Contact
        </h3>
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
        <h3 id="info-title" className={styles.detailsLabel}>
          Store info
        </h3>
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
          <div>
            <dt>Status</dt>
            <dd className={store.is_active ? styles.good : styles.warn}>{store.is_active ? 'Open' : 'Taking a break'}</dd>
          </div>
        </dl>
      </section>

      <section aria-labelledby="safety-title">
        <h3 id="safety-title" className={styles.detailsLabel}>
          Buying safely
        </h3>
        <p className={styles.safety}>
          🛡 Pay only through BROKA. Your money is held in escrow, and the seller is paid once you confirm you have the
          item. Never send money to a seller directly.
        </p>
      </section>
    </aside>
  )
}
