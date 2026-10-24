// "Store details": everything a visitor arriving from a shared link needs to
// know about a store before buying from it - which store it is, who runs it
// and their record (deals done, rating, the year they joined), the shop's
// photos, what it says about itself, where it is, how to reach it, and how
// to pay the store safely while BROKA holds no payments (lib/safety.ts). The
// same sections, in the same order, as the app's Store details screen
// (store_details_view.dart).
//
// Its own page (/store/<name>/about), linked from "More details" under the
// store's name, so the store's home is left to its products.
import { monthYearOf, placeLine, plural, yearOf } from '@/lib/format'
import { asset, storeDetailsPath } from '@/lib/links'
import {
  buyerStars,
  replyTimeLabel,
  reviewCountLabel,
  reviewDate,
  starsFromStoreScore,
} from '@/lib/ratings'
import { PAYING_SAFELY } from '@/lib/safety'
import type { StoreView } from '@/lib/storefront'
import type { StoreReviews } from '@/lib/types'

import { EscrowBox } from './EscrowBox'
import { Stars } from './Stars'
import styles from './store.module.css'

export function StoreDetails({
  view,
  reviews = null,
  reviewsFailed = false,
}: {
  view: StoreView
  /** The shop's buyer reviews; null when the API sent none. */
  reviews?: StoreReviews | null
  /** The reviews request failed - say so rather than claim there are none. */
  reviewsFailed?: boolean
}) {
  const { store } = view
  const owner = store.owner
  const ownerName = owner?.name?.trim() || `The owner of ${store.name}`
  const deals = owner?.completed_deals ?? 0
  // Buyer reviews, not deals, make a seller average. A seller can finish
  // many deals and still have been rated by nobody; the legacy 5.0 account
  // default must not stand in for a review (backend reviews/stats.py).
  const ownerReviews = owner?.review_count ?? 0
  const sellerRating =
    ownerReviews > 0 && owner?.rating != null ? owner.rating.toFixed(1) : null
  const since = yearOf(owner?.member_since)
  // The reviews response is authoritative for the count: the store payload
  // can still say zero for a moment after a review lands. Falling back to it
  // only when the reviews request never answered keeps a transient failure
  // from erasing a count the store already had.
  const storeReviewCount = reviews?.summary?.count ?? store.review_count ?? 0
  const reply = replyTimeLabel(reviews?.seller_standing?.median_response_minutes)
  const summary = reviews?.summary ?? null
  const opened = monthYearOf(store.created_at)
  // For an online store the equivalent of "where it is" is where it
  // delivers; the county fields are for premises and must not be shown as
  // an address a buyer could visit.
  const summaryLine = [store.category, view.isVirtual ? view.delivery : placeLine(store.subcounty, store.county)]
    .filter(Boolean)
    .join(' · ')
  const area = placeLine(store.subcounty, store.county) ?? store.country
  const landmark = store.location_description?.trim() || null
  const mapQuery = placeLine(store.location_description, store.subcounty, store.county, store.country)
  const email = store.business_email && store.business_email_verified ? store.business_email : null

  return (
    <div className={styles.storeDetails}>
      <div className={`card ${styles.detailsCard} ${styles.summary}`}>
        {/* The store's own logo, or BROKA's when it uploaded none - never
            an initial in a box, which read as a missing picture. */}
        <div className={styles.summaryLogo}>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={view.logo ?? asset('/logo.png')} alt="" />
        </div>
        <div>
          <p className={styles.ownerName}>{store.name}</p>
          {summaryLine && <p className={styles.mutedLine}>{summaryLine}</p>}
          <p className={styles.mutedLine}>
            {view.isVirtual ? 'Online store · no shop to visit' : 'Physical store'}
          </p>
          <p className={store.is_active ? styles.statusOpen : styles.statusPaused}>
            {store.is_active ? 'Open' : 'Taking a break'}
          </p>
          {!view.isVirtual && view.hours.length > 0 && (
            <p className={view.openNow ? styles.statusOpen : styles.mutedLine}>{view.openLabel}</p>
          )}
        </div>
      </div>

      {store.rating != null && (
        <section aria-labelledby="score-title">
          <h2 id="score-title" className={styles.detailsLabel}>
            Store score
          </h2>
          <div className={`card ${styles.detailsCard} ${styles.scoreCard}`}>
            <div className={styles.scoreHeadline}>
              {/* The scale is part of the figure. Without it, 6.5 beside five
                  stars reads as 6.5/5 (and drew as five filled stars). */}
              <p className={styles.scoreNumber}>
                {store.rating.toFixed(1)}
                <span className={styles.scoreScale}>/10</span>
              </p>
              <Stars
                value={starsFromStoreScore(store.rating)}
                label={`Store score ${store.rating.toFixed(1)} out of 10`}
                size={16}
              />
            </div>
            <div className={styles.scoreEvidence}>
              <p className={styles.strongLine}>
                {storeReviewCount === 0 ? 'No buyer reviews yet' : `${reviewCountLabel(storeReviewCount)} so far`}
              </p>
              <p className={styles.mutedLine}>
                Built from this shop&apos;s buyer reviews, how fast it answers and how long it has traded
                on BROKA. Different from the seller&apos;s buyer rating below, which is out of 5.
              </p>
              {reply && <p className={styles.mutedLine}>⏱ {reply}</p>}
            </div>
          </div>
        </section>
      )}

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
              <dt>{sellerRating ? `Rating · ${reviewCountLabel(ownerReviews)}` : 'No reviews yet'}</dt>
              <dd>
                <span className={`${styles.factIcon} ${styles.star}`} aria-hidden="true">
                  ★
                </span>
                {sellerRating ? `${sellerRating}/5` : 'New'}
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

      <section aria-labelledby="reviews-title" id="reviews">
        <h2 id="reviews-title" className={styles.detailsLabel}>
          Buyer reviews
        </h2>
        {reviewsFailed ? (
          <div className={`card ${styles.detailsCard}`}>
            <p className={styles.strongLine}>Reviews aren&apos;t available right now.</p>
            <p className={styles.mutedLine}>
              The rest of the store is fine.{' '}
              <a className={styles.reviewsRetry} href={storeDetailsPath(store.slug)}>
                Try again
              </a>
            </p>
          </div>
        ) : summary == null || summary.count === 0 ? (
          <div className={`card ${styles.detailsCard}`}>
            <p className={styles.strongLine}>No reviews yet</p>
            <p className={styles.mutedLine}>
              Reviews come from buyers who had a deal on this store&apos;s products. They are written in
              the BROKA app, and yours will help the next buyer.
            </p>
          </div>
        ) : (
          <>
            <div className={`card ${styles.detailsCard} ${styles.reviewSummary}`}>
              <div>
                {/* The buyer-review scale, labelled. The shop score above is
                    a different figure out of 10. */}
                <p className={styles.scoreNumber}>
                  {(summary.avg ?? 0).toFixed(1)}
                  <span className={styles.scoreScale}>/5</span>
                </p>
                <Stars
                  value={buyerStars(summary.avg ?? 0)}
                  label={`Buyer rating ${(summary.avg ?? 0).toFixed(1)} out of 5`}
                />
                <p className={styles.mutedLine}>{reviewCountLabel(summary.count)}</p>
              </div>
              <div className={styles.distribution} aria-label="Ratings breakdown">
                {[5, 4, 3, 2, 1].map((star) => {
                  const n = summary.distribution[String(star)] ?? 0
                  return (
                    <div key={star} className={styles.distributionRow}>
                      <span className={styles.distributionStar}>{star} ★</span>
                      <span className={styles.distributionBar}>
                        <span style={{ width: `${(n / summary.count) * 100}%` }} />
                      </span>
                      <span className={styles.distributionCount}>{n}</span>
                    </div>
                  )
                })}
              </div>
            </div>
            <ul className={styles.reviews} aria-label={`Buyer reviews of ${store.name}`}>
              {reviews?.reviews.map((review) => {
                const name = review.reviewer_name?.trim() || 'BROKA buyer'
                const date = reviewDate(review.created_at)
                return (
                  <li key={review.id} className={`card ${styles.reviewCard}`}>
                    <div className={styles.reviewHead}>
                      <span className={styles.reviewAvatar} aria-hidden="true">
                        {Array.from(name)[0] ?? 'B'}
                      </span>
                      <div>
                        <p className={styles.reviewName}>{name}</p>
                        {date && <p className={styles.reviewDate}>{date}</p>}
                      </div>
                      <Stars value={review.rating} label={`${review.rating} out of 5 stars`} size={13} />
                    </div>
                    {review.comment?.trim() && <p className={styles.reviewText}>{review.comment.trim()}</p>}
                  </li>
                )
              })}
            </ul>
            {summary.count > (reviews?.reviews.length ?? 0) && (
              <p className={styles.mutedLine}>
                Showing {reviews?.reviews.length ?? 0} of {reviewCountLabel(summary.count)}
              </p>
            )}
            <p className={styles.reviewsNote}>
              Reviews are written in the BROKA app by buyers who had a deal on this store&apos;s products.
            </p>
          </>
        )}
      </section>

      {view.photos.length > 0 && !view.isVirtual && (
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

      {view.isVirtual ? (
        <section aria-labelledby="delivery-title">
          <h2 id="delivery-title" className={styles.detailsLabel}>
            Delivery and service area
          </h2>
          <div className={`card ${styles.detailsCard}`}>
            <p className={styles.strongLine}>🚚 {view.delivery ?? 'Where it delivers: ask the store'}</p>
            {view.deliveryNote && <p className={styles.strongLine}>{view.deliveryNote}</p>}
            <p className={styles.mutedLine}>
              This is an online store: there is no shop to visit. Agree delivery or collection with the seller
              in the product chat.
            </p>
          </div>
        </section>
      ) : (
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
      )}

      {!view.isVirtual && view.hours.length > 0 && (
        <section aria-labelledby="hours-title">
          <h2 id="hours-title" className={styles.detailsLabel}>
            Opening hours
          </h2>
          <div className={`card ${styles.detailsCard}`}>
            <p className={view.openNow ? styles.statusOpen : styles.strongLine}>{view.openLabel}</p>
            <dl className={styles.infoList}>
              {view.hours.map((row) => (
                <div key={row.day}>
                  <dt>{row.label}</dt>
                  <dd className={row.closed ? styles.mutedLine : undefined}>{row.hours}</dd>
                </div>
              ))}
            </dl>
            <p className={styles.mutedLine}>Times are East Africa Time (Africa/Nairobi).</p>
          </div>
        </section>
      )}

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
          <div>
            <dt>Type</dt>
            <dd>{view.isVirtual ? 'Online store' : 'Physical store'}</dd>
          </div>
          {store.category && (
            <div>
              <dt>Sells</dt>
              <dd>{store.category}</dd>
            </div>
          )}
          {!view.isVirtual && (
            <div>
              <dt>Opening hours</dt>
              <dd>{view.hours.length > 0 ? view.openLabel : 'Opening hours unavailable'}</dd>
            </div>
          )}
          {view.delivery && (
            <div>
              <dt>Delivery</dt>
              <dd>{view.delivery}</dd>
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
        {/* This section used to send buyers to BROKA to pay, never to the
            seller: with payments paused, the opposite of what they must do,
            and the script of a "pay BROKA here" scam. */}
        <ul className={styles.safety}>
          {PAYING_SAFELY.map((a) => (
            <li key={a.lead}>
              <strong>{a.lead}</strong> {a.text}
            </li>
          ))}
        </ul>
        <EscrowBox />
      </section>
    </div>
  )
}
