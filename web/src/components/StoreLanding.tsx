// A store's home: the shop's front window, built like a flagship's screen.
//
// The hero carries the store's name in light over its own cover, its
// record as a readout (store score, deals, products, how fast it answers -
// only figures the API sends, never a guess), and its first product
// floating over the cover with Add to cart, so a visitor arriving from a
// shared link can buy from the first screen (STORES_UI_REVIEW.md H1). Then
// a ticker of what buying here means, the perks, the store's collections,
// a selection of its products, what its buyers say, its own story, and a
// last way into the whole catalogue.
//
// Each store's hero is lit in its category's colours (lib/categories.ts,
// the same pair the app uses), so a food shop and a phone shop don't open
// on the same violet (STORES_UI_REVIEW.md M3).
import Link from 'next/link'
import type { CSSProperties } from 'react'

import { storeCategoryTiles } from '@/components/CategoryPills'
import { type ProductCardData, filtersQuery } from '@/lib/catalogue'
import { categoryArtPath } from '@/lib/category-art'
import { plural } from '@/lib/format'
import { storeDetailsPath, storeMessagesPath, storeShopPath } from '@/lib/links'
import { buyerStars, replyTimeLabel, reviewCountLabel, reviewDate } from '@/lib/ratings'
import { PERK_PAY_DIRECT, PERK_SEE_FIRST } from '@/lib/safety'
import type { StoreCategory, StoreReviews } from '@/lib/types'
import type { StoreView } from '@/lib/storefront'

import { AddToCart } from './AddToCart'
import { AppButton } from './AppButton'
import { Icon } from './Icon'
import { Perks } from './Perks'
import { Price } from './Price'
import { ProductCard } from './ProductCard'
import { Stars } from './Stars'
import styles from './store-landing.module.css'

const HEX = /^#[0-9a-f]{6}$/i

/** A category colour at an alpha (two hex digits), or the colour alone. */
const tint = (hex: string | undefined, alpha: string) => (hex && HEX.test(hex) ? `${hex}${alpha}` : undefined)

/** The store's measured reply time, as a figure and its unit: "25" "min". */
function replyFigure(minutes: number | null | undefined): { value: string; unit: string } | null {
  if (minutes == null || Number.isNaN(minutes) || minutes < 0) return null
  if (minutes < 1) return { value: '<1', unit: 'min' }
  if (minutes < 60) return { value: String(Math.round(minutes)), unit: 'min' }
  if (minutes < 1440) return { value: (minutes / 60).toFixed(1).replace(/\.0$/, ''), unit: 'h' }
  return { value: (minutes / 1440).toFixed(1).replace(/\.0$/, ''), unit: 'days' }
}

/** Two digits, as the sections number themselves: 01, 02... */
const index = (n: number) => String(n).padStart(2, '0')

export function StoreLanding({
  view,
  categories,
  products,
  storeId,
  reviews = null,
}: {
  view: StoreView
  categories: StoreCategory[]
  products: ProductCardData[]
  storeId: string
  /** The store's buyer reviews, for "What buyers say"; null hides it. */
  reviews?: StoreReviews | null
}) {
  const { store } = view
  const owner = store.owner
  const shopPath = storeShopPath(store.slug)
  const [spotlight, ...moreProducts] = products
  const mappedTiles = storeCategoryTiles(categories)
  const tiles = mappedTiles.length ? mappedTiles : view.sellCategories.map((name) => ({
    name,
    parent: name,
    count: 0,
    category: name,
    subcategoryId: null,
    art: categoryArtPath(name),
  }))
  const shownTiles = tiles.slice(0, 5)
  const shownProducts = moreProducts.slice(0, 8)
  const heroImage = view.cover?.src ?? view.photos[0]?.src ?? null
  const heroSrcSet = view.cover?.src && heroImage === view.cover.src ? view.cover.srcSet ?? undefined : undefined
  const primaryHref = products.length > 0 ? shopPath : tiles.length > 0 ? '#collections-title' : shopPath
  const primaryLabel = products.length > 0 ? 'Shop all products' : tiles.length > 0 ? 'Explore collections' : 'Visit the shop'
  const context = [store.category, view.isVirtual ? view.delivery : view.place].filter(Boolean).join(' · ')
  const description = view.description || (spotlight
    ? `Explore the collection from ${store.name} and see what is available today.`
    : `Browse ${store.name}'s departments and check back as new products are added.`)
  const deals = owner?.completed_deals ?? 0
  // When it opens, for a shop with premises and hours: only what the
  // store's record says, never a guess. (An online store's delivery area is
  // already on the line under its name.)
  const status = !view.isVirtual && view.hours.length > 0 ? view.openLabel : null
  const reply = replyFigure(store.response_minutes)
  // The same reply time as a sentence, in the store details page's words:
  // the readout's "<1" figure read "about <1 min" there.
  const replyLine = replyTimeLabel(store.response_minutes)
  const fallbackArt = categoryArtPath(store.category)
  // With store orders on, a question needs no app: the conversation is on
  // the website, so it is the hero's second action. Without them it opens
  // the app, and stays with the store's story further down.
  const webMessages = store.is_active && Boolean(owner) && store.orders_enabled === true
  const appMessages = store.is_active && Boolean(owner) && store.orders_enabled !== true
  // Buyer reviews worth quoting: the ones with words in them, newest first
  // as the API sends them.
  const quoted = (reviews?.reviews ?? [])
    .flatMap((review) => {
      const text = review.comment?.trim()
      return text ? [{ ...review, text }] : []
    })
    .slice(0, 3)
  const reviewSummary = reviews?.summary && reviews.summary.count > 0 ? reviews.summary : null
  // The record, as figures: each only when the API sends it. The store
  // score is out of 10 and says so; the buyer average (out of 5) is with
  // the reviews below, never beside it.
  const readout: Array<{ key: string; value: string; unit?: string; label: string; gauge?: number }> = []
  if (store.rating != null) {
    readout.push({ key: 'score', value: store.rating.toFixed(1), unit: '/10', label: 'Store score', gauge: Math.min(Math.max(store.rating / 10, 0), 1) })
  }
  if (deals > 0) readout.push({ key: 'deals', value: String(deals), label: deals === 1 ? 'Deal done' : 'Deals done' })
  if (store.listing_count > 0) {
    readout.push({ key: 'products', value: String(store.listing_count), label: store.listing_count === 1 ? 'Product' : 'Products' })
  }
  if (reply) readout.push({ key: 'reply', value: reply.value, unit: reply.unit, label: 'Usual reply' })
  // The ticker under the hero: what buying here means, and what the store
  // sells - decoration (aria-hidden); the perks below say it to everyone.
  const tickerItems = [
    PERK_SEE_FIRST.title,
    PERK_PAY_DIRECT.title,
    'M-Pesa',
    'Delivery agreed with the store',
    ...(owner?.verified ? ['Verified seller'] : []),
    ...shownTiles.map((t) => t.name),
  ]
  // Each of the ticker's two copies must be wider than a wide screen, or
  // the loop shows a gap: a short list is said twice per copy.
  const ticker = tickerItems.length < 9 ? [...tickerItems, ...tickerItems] : tickerItems
  const spotlightBuyable = Boolean(spotlight && !spotlight.isAuction && (spotlight.availability ?? 'available') === 'available')
  const [tintA, tintB] = view.gradient
  const lit = {
    '--tint-a': tintA,
    '--tint-a-soft': tint(tintA, '3d'),
    '--tint-b-soft': tint(tintB ?? tintA, '33'),
  } as CSSProperties
  let section = 0

  return (
    <div className={styles.landing} style={lit}>
      <main id="main-content" className={styles.main}>
        <section className={styles.hero} aria-labelledby="landing-title">
          <span className={styles.heroAtmos} aria-hidden="true" />
          <div className={styles.heroCopy}>
            <p className={styles.eyebrow}>
              <span className={styles.eyebrowDot} aria-hidden="true" />
              {store.category || 'Independent store'} <span>·</span> On BROKA
            </p>
            <h1 id="landing-title" className={styles.title} data-long={store.name.length > 16 || undefined}>
              {store.name}
            </h1>
            {context && (
              <p className={styles.context}>
                <Icon name={view.isVirtual ? 'truck' : 'pin'} size={15} />
                <span>{context}</span>
              </p>
            )}
            <p className={styles.description}>{description}</p>
            <div className={styles.actions}>
              {store.is_active && (
                <Link href={primaryHref} className={styles.primaryAction}>
                  {primaryLabel} <Icon name="arrow" size={18} />
                </Link>
              )}
              {webMessages ? (
                <Link href={storeMessagesPath(store.slug)} className={styles.secondaryAction} data-testid="message-store">
                  <Icon name="chat" size={18} /> Message this store
                </Link>
              ) : (
                <Link href={storeDetailsPath(store.slug)} className={styles.secondaryAction}>
                  <Icon name="info" size={18} /> Store details
                </Link>
              )}
            </div>
            <ul className={styles.proof} aria-label="This store's record">
              {owner?.verified && (
                <li className={styles.proofVerified}>
                  <Icon name="verified" size={15} /> Verified seller
                </li>
              )}
              {store.is_active && owner?.online && (
                <li className={styles.proofOpen}>
                  <span className={styles.liveDot} aria-hidden="true" /> Seller online now
                </li>
              )}
              {status && store.is_active && (
                <li className={view.openNow ? styles.proofOpen : undefined}>
                  {view.openNow ? <span className={styles.liveDot} aria-hidden="true" /> : <Icon name="clock" size={14} />}
                  {status}
                </li>
              )}
              {store.rating == null && !owner?.verified && deals === 0 && store.is_active && (
                <li>
                  <Icon name="store" size={14} /> Shop directly with the store
                </li>
              )}
            </ul>
            {!store.is_active && <p className={styles.paused} role="status">This store is taking a break right now.</p>}
          </div>

          <div className={styles.stage}>
            <Link href={shopPath} className={styles.heroVisual} aria-label={`Browse ${store.name} products`}>
              {heroImage ? (
                // eslint-disable-next-line @next/next/no-img-element
                <img
                  src={heroImage}
                  srcSet={heroSrcSet}
                  sizes="(max-width: 860px) 100vw, 56vw"
                  alt=""
                  fetchPriority="high"
                />
              ) : (
                // No cover yet: the store's initial, lit, over its
                // category's art held back in the dark - the store's own
                // sign first, not a stock picture passed off as its shop.
                <span className={styles.visualFallback} aria-hidden="true">
                  {fallbackArt && (
                    // eslint-disable-next-line @next/next/no-img-element
                    <img src={fallbackArt} alt="" className={styles.visualFallbackArt} />
                  )}
                  <span className={styles.visualMonogram}>{view.initial}</span>
                </span>
              )}
              <span className={styles.visualShade} />
              <span className={styles.visualScan} />
              <span className={styles.visualFrame} />
              <span className={styles.visualTag}>
                <span className={styles.eyebrowDot} aria-hidden="true" /> A look inside this store
              </span>
              <span className={styles.visualCaption}>
                <strong>{store.listing_count > 0 ? plural(store.listing_count, 'product') : 'Collections'}</strong>
                <span>{store.listing_count > 0 ? 'to explore' : 'to discover'}</span>
                <span className={styles.visualArrow} aria-hidden="true">
                  <Icon name="arrow" size={16} />
                </span>
              </span>
            </Link>
            {spotlight && (
              <div className={styles.spotlight} data-spot>
                <Link href={spotlight.href} className={styles.spotlightLink}>
                  <span className={styles.spotlightImage}>
                    {spotlight.image ? (
                      // eslint-disable-next-line @next/next/no-img-element
                      <img src={spotlight.image} srcSet={spotlight.imageSrcSet ?? undefined} sizes="96px" alt="" />
                    ) : (
                      <span aria-hidden="true">{spotlight.emoji}</span>
                    )}
                  </span>
                  <span className={styles.spotlightText}>
                    <small>Featured</small>
                    <strong>{spotlight.name}</strong>
                    <Price label={spotlight.priceLabel} className={styles.spotlightPrice} />
                  </span>
                  <span className={styles.spotlightGo} aria-hidden="true">
                    <Icon name="chevron" size={18} />
                  </span>
                </Link>
                {spotlightBuyable && (
                  <div className={styles.spotlightBuy}>
                    <AddToCart storeId={storeId} product={spotlight} />
                  </div>
                )}
              </div>
            )}
          </div>

          {readout.length > 0 && (
            <dl className={styles.readout} data-count={readout.length}>
              {readout.map((r) => (
                <div key={r.key} className={styles.reading}>
                  <dt>{r.label}</dt>
                  <dd>
                    {r.gauge != null && (
                      // The score's dial: decoration beside the figure,
                      // which says it in words.
                      <svg className={styles.gauge} viewBox="0 0 44 44" aria-hidden="true" focusable="false">
                        <circle cx="22" cy="22" r="18" pathLength={100} className={styles.gaugeTrack} />
                        <circle
                          cx="22"
                          cy="22"
                          r="18"
                          pathLength={100}
                          className={styles.gaugeFill}
                          style={{ strokeDasharray: `${Math.round(r.gauge * 100)} 100` }}
                        />
                      </svg>
                    )}
                    <span className={styles.readingValue}>{r.value}</span>
                    {r.unit && <span className={styles.readingUnit}>{r.unit}</span>}
                  </dd>
                </div>
              ))}
            </dl>
          )}
        </section>

        {store.is_active && (
          <div className={styles.ticker} aria-hidden="true">
            <div className={styles.tickerTrack}>
              {[0, 1].map((copy) => (
                <ul key={copy} className={styles.tickerRow}>
                  {ticker.map((item, i) => (
                    <li key={`${item}-${i}`}>{item}</li>
                  ))}
                </ul>
              ))}
            </div>
          </div>
        )}

        {store.is_active && (
          <div className={`${styles.perks} reveal`}>
            <Perks verified={Boolean(owner?.verified)} />
          </div>
        )}

        {shownTiles.length > 0 && (
          <section className={`${styles.section} reveal`} aria-labelledby="collections-title">
            <div className={styles.sectionHead}>
              <div>
                <p className={styles.sectionEyebrow}>
                  <span className={styles.sectionIndex} aria-hidden="true">{index(++section)}</span> Explore the store
                </p>
                <h2 id="collections-title">Shop by collection</h2>
              </div>
              <Link href={shopPath} className={styles.textLink}>View all <Icon name="arrow" size={15} /></Link>
            </div>
            <nav className={styles.collections} aria-label="Shop collections" data-count={shownTiles.length}>
              {shownTiles.map((tile, i) => {
                const href = `${shopPath}${filtersQuery({ category: tile.category, subcategoryId: tile.subcategoryId })}`
                return (
                  <Link key={tile.subcategoryId ?? tile.name} href={href} className={styles.collection} data-spot>
                    {tile.art ? (
                      // eslint-disable-next-line @next/next/no-img-element
                      <img src={tile.art} alt="" loading="lazy" decoding="async" />
                    ) : <span className={styles.collectionMonogram} aria-hidden="true">{tile.parent.slice(0, 1)}</span>}
                    <span className={styles.collectionShade} />
                    <span className={styles.collectionIndex} aria-hidden="true">{index(i + 1)}</span>
                    <span className={styles.collectionText}>
                      <strong>{tile.name}</strong>
                      {tile.count > 0 && <small>{tile.count} {tile.count === 1 ? 'item' : 'items'}</small>}
                    </span>
                    <span className={styles.collectionArrow} aria-hidden="true">
                      <Icon name="arrow" size={15} />
                    </span>
                  </Link>
                )
              })}
            </nav>
          </section>
        )}

        {shownProducts.length > 0 && (
          <section className={`${styles.section} reveal`} aria-labelledby="products-title">
            <div className={styles.sectionHead}>
              <div>
                <p className={styles.sectionEyebrow}>
                  <span className={styles.sectionIndex} aria-hidden="true">{index(++section)}</span> Selected from the shop
                </p>
                <h2 id="products-title">More to discover</h2>
              </div>
              <Link href={shopPath} className={styles.textLink}>Shop all <Icon name="arrow" size={15} /></Link>
            </div>
            <div className={styles.products} data-count={Math.min(shownProducts.length, 4)}>
              {shownProducts.map((product) => (
                <ProductCard key={product.id} product={product} storeId={storeId} />
              ))}
            </div>
          </section>
        )}

        {reviewSummary && quoted.length > 0 && (
          <section className={`${styles.section} reveal`} aria-labelledby="buyers-title" data-testid="buyer-quotes">
            <div className={styles.sectionHead}>
              <div>
                <p className={styles.sectionEyebrow}>
                  <span className={styles.sectionIndex} aria-hidden="true">{index(++section)}</span> From buyers on BROKA
                </p>
                <h2 id="buyers-title">What buyers say</h2>
              </div>
              <Link href={`${storeDetailsPath(store.slug)}#reviews`} className={styles.textLink}>
                All reviews <Icon name="arrow" size={15} />
              </Link>
            </div>
            <div className={styles.quotes}>
              {/* The buyer-review average is out of 5 - a different figure
                  from the store's 0-10 score in the hero, and labelled so. */}
              <div className={styles.quoteSummary}>
                <p className={styles.quoteScore}>
                  {(reviewSummary.avg ?? 0).toFixed(1)}
                  <span>/5</span>
                </p>
                <Stars
                  value={buyerStars(reviewSummary.avg ?? 0)}
                  label={`Buyer rating ${(reviewSummary.avg ?? 0).toFixed(1)} out of 5`}
                  size={18}
                />
                <p className={styles.quoteCount}>From {reviewCountLabel(reviewSummary.count)}</p>
              </div>
              {quoted.map((review) => {
                const name = review.reviewer_name?.trim() || 'BROKA buyer'
                const date = reviewDate(review.created_at)
                return (
                  <figure key={review.id} className={styles.quote} data-spot>
                    <Stars value={review.rating} label={`${review.rating} out of 5 stars`} size={14} />
                    <blockquote>{review.text}</blockquote>
                    <figcaption>
                      <span className={styles.quoteAvatar} aria-hidden="true">
                        {(Array.from(name)[0] ?? 'B').toUpperCase()}
                      </span>
                      <span>
                        <strong>{name}</strong>
                        {date && <small>{date}</small>}
                      </span>
                    </figcaption>
                  </figure>
                )
              })}
            </div>
          </section>
        )}

        {products.length === 0 && store.is_active && (
          <section className={`${styles.newStore} reveal`} aria-label="New store">
            <span className={styles.newStoreMark} aria-hidden="true">{view.initial}</span>
            <div>
              <p className={styles.sectionEyebrow}>The shop is just getting started</p>
              <h2>New things are on the way.</h2>
              <p>{store.name} hasn&apos;t added products yet. Browse the collections above or check back soon.</p>
            </div>
          </section>
        )}

        {(view.description || owner) && (
          <section className={`${styles.about} reveal`} aria-labelledby="about-store-title">
            <span className={styles.aboutMark} aria-hidden="true">
              {view.logo ? (
                // eslint-disable-next-line @next/next/no-img-element
                <img src={view.logo} alt="" loading="lazy" />
              ) : (
                view.initial
              )}
            </span>
            <div className={styles.aboutBody}>
              <p className={styles.sectionEyebrow}>A note from the shop</p>
              <h2 id="about-store-title">About {store.name}</h2>
              {view.description && <p>{view.description}</p>}
              {(view.place || view.delivery || replyLine) && (
                <ul className={styles.aboutFacts}>
                  {!view.isVirtual && view.place && (
                    <li>
                      <Icon name="pin" size={15} /> {view.place}
                    </li>
                  )}
                  {view.delivery && (
                    <li>
                      <Icon name="truck" size={15} /> {view.delivery}
                    </li>
                  )}
                  {replyLine && (
                    <li>
                      <Icon name="chat" size={15} /> {replyLine}
                    </li>
                  )}
                </ul>
              )}
            </div>
            <div className={styles.aboutActions}>
              <Link href={storeDetailsPath(store.slug)} className={styles.textLink}>Read the store story <Icon name="arrow" size={15} /></Link>
              {appMessages && <AppButton storeChat label="Message this store" className={styles.aboutChat} />}
            </div>
          </section>
        )}

        {store.is_active && store.listing_count > 0 && products.length > 0 && (
          <section className={`${styles.closer} reveal`} aria-labelledby="closer-title" data-spot>
            <span className={styles.closerGlow} aria-hidden="true" />
            <p className={styles.sectionEyebrow}>The full catalogue</p>
            <h2 id="closer-title">Everything from {store.name}, in one place.</h2>
            <p>
              {plural(store.listing_count, 'product')}
              {view.sellCategories.length > 0 ? ` across ${view.sellCategories.slice(0, 3).join(', ')}` : ''}. Search, filter
              by price and condition, and order straight from the store.
            </p>
            <Link href={shopPath} className={styles.primaryAction}>
              Browse the catalogue <Icon name="arrow" size={18} />
            </Link>
          </section>
        )}
      </main>
    </div>
  )
}
