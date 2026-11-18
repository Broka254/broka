// One product in a store: https://broka.co.ke/store/<name>/p/<id> - a shop's
// product page: the path back through the store, the gallery, the price,
// how many, Add to cart and Buy now, the seller, and more from the store.
// Deals are agreed in the BROKA app, and paid to the store directly while
// BROKA holds no payments (lib/safety.ts) - the box under the buy buttons
// says so; this page is what a shared product link opens.
import type { Metadata } from 'next'
import Link from 'next/link'
import { notFound, permanentRedirect, redirect } from 'next/navigation'

import { AppButton } from '@/components/AppButton'
import { CartDrawer } from '@/components/CartDrawer'
import { EscrowBox } from '@/components/EscrowBox'
import { Gallery } from '@/components/Gallery'
import { Icon } from '@/components/Icon'
import { Price } from '@/components/Price'
import { ProductBuyBox } from '@/components/ProductBuyBox'
import { ProductCard } from '@/components/ProductCard'
import { ProductStickyBar } from '@/components/ProductStickyBar'
import { ShareButtons } from '@/components/ShareButtons'
import { StoreAvatar } from '@/components/StoreAvatar'
import { StoreFooter } from '@/components/StoreFooter'
import { StoreHeader } from '@/components/StoreHeader'
import { StorefrontShell } from '@/components/StorefrontShell'
import { TrustChips } from '@/components/TrustChips'
import { VisitBeacon } from '@/components/VisitBeacon'
import shopStyles from '@/components/shop.module.css'
import styles from '@/components/store.module.css'
import { getEscrowDirectory, getListing, getStore, getStoreListings } from '@/lib/api'
import { filtersQuery, toProductCard } from '@/lib/catalogue'
import { clip, conditionLabel, formatPrice, plural } from '@/lib/format'
import {
  campaignToken,
  productPath,
  storeCartPath,
  storeMessagesPath,
  storePath,
  storeShopPath,
  viaTag,
} from '@/lib/links'
import { NO_DEPOSIT, PAY_LINE, SEE_FIRST } from '@/lib/safety'
import { API_URL } from '@/lib/server-config'
import {
  jsonLdScript,
  productJsonLd,
  productPreviewImage,
  productView,
  storeView,
} from '@/lib/storefront'

type Props = {
  params: Promise<{ name: string; listingId: string }>
  searchParams: Promise<Record<string, string | string[] | undefined>>
}

/** The listing, if it belongs to this store. */
async function load(name: string, listingId: string) {
  const [store, listing] = await Promise.all([getStore(name), getListing(listingId)])
  if (!store || !listing || listing.store_id !== store.id) return null
  return { store, listing }
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { name, listingId } = await params
  const found = await load(name, listingId)
  if (!found) return { title: 'Product not found', robots: { index: false } }
  const { store, listing } = found
  if (!store.is_active) return { title: store.name, robots: { index: false } }
  const view = productView(listing, store.slug)
  const title = `${listing.name} · ${formatPrice(listing.price)}`
  const description = listing.description?.trim()
    ? clip(listing.description)
    : `${listing.name} for ${formatPrice(listing.price)} from ${store.name} on BROKA.`
  const image = productPreviewImage(listing)
  return {
    title: `${listing.name} · ${store.name}`,
    description,
    alternates: { canonical: view.path },
    robots: view.available ? undefined : { index: false },
    openGraph: { type: 'website', url: view.url, title, description, images: [image] },
    twitter: { card: 'summary_large_image', title, description, images: [image.url] },
  }
}

export default async function ProductPage({ params, searchParams }: Props) {
  const [{ name, listingId }, query] = await Promise.all([params, searchParams])
  const found = await load(name, listingId)
  if (!found) notFound()
  const { store, listing } = found
  const via = viaTag(query.via)
  const campaign = campaignToken(query.c)
  if (name !== store.slug) {
    const q = new URLSearchParams()
    if (via) q.set('via', via)
    if (campaign) q.set('c', campaign)
    permanentRedirect(`${productPath(store.slug, listing.id)}${q.size ? `?${q}` : ''}`)
  }
  // A paused store shows no products: its own page says it's paused, and a
  // product link shared before the pause goes there too, rather than
  // selling from a store its owner closed. Temporary: it may reopen.
  if (!store.is_active) redirect(`${storePath(store.slug)}${via ? `?via=${via}` : ''}`)

  const shop = storeView(store)
  const view = productView(listing, store.slug)
  const facts = [
    conditionLabel(listing.condition),
    listing.category,
    view.place,
    listing.listing_type === 'auction' ? 'Auction' : null,
  ].filter((f): f is string => Boolean(f))

  // More from the store, below the details: the product page isn't a dead
  // end (STORES_UI_REVIEW.md M1).
  const more = (await getStoreListings(store.id, { limit: 9 }).catch(() => []))
    .filter((l) => l.id !== listing.id)
    .slice(0, 8)
    .map((l) => toProductCard(l, store.slug, API_URL))
  const card = toProductCard(listing, store.slug, API_URL)
  const cartPath = storeCartPath(store.slug)
  const escrow = await getEscrowDirectory()
  // Store orders switch the web on for buying and asking (STORE_ORDERS.md).
  const webCommerce = store.orders_enabled === true
  const askPath = storeMessagesPath(store.slug, listing.id)
  // Why a buyer can't order it now, if they can't: removed or sold, none
  // left to order (chat deals and accepted orders took it), or paused by
  // the seller. A product whose every unit is promised or sold and whose
  // stock the seller doesn't count is no longer active: it reads as gone.
  const unavailable: 'gone' | 'out_of_stock' | 'paused' | null =
    listing.status !== 'active' || listing.reported_sold_out
      ? 'gone'
      : listing.temporarily_unavailable
        ? 'paused'
        : listing.out_of_stock || card.availability === 'out_of_stock'
          ? 'out_of_stock'
          : !view.available
            ? 'gone'
            : null
  const buyable = unavailable === null && listing.listing_type !== 'auction'
  const buyLine = {
    id: card.id,
    name: card.name,
    price: card.price,
    unit: card.unit,
    image: card.image,
    emoji: card.emoji,
    href: card.href,
    max: card.maxQuantity,
  }
  // Beside the price, as on the product's card: what is left to order, when
  // the API counts it.
  const stock =
    unavailable === null && card.quantity != null && card.quantity > 0
      ? { low: card.quantity <= 3, label: card.quantity <= 3 ? `Only ${card.quantity} left` : 'In stock' }
      : null
  // The seller's record in one line under the name. Reviews, not deals,
  // make a rating (TrustChips.tsx): no reviews, no stars.
  const sellerReviews = listing.seller_review_count ?? 0
  const sellerRating = sellerReviews > 0 && listing.seller_rating != null ? listing.seller_rating : null
  const deals = listing.seller_completed_deals ?? 0

  return (
    <StorefrontShell>
      <StoreHeader view={shop} active="product" searchBase={storeShopPath(store.slug)} />
      <main id="main-content" className={`page ${shopStyles.storePage}`}>
        <nav aria-label="Breadcrumb" className={shopStyles.crumbs}>
          <Link href={shop.path}>{store.name}</Link>
          <Icon name="chevron" size={14} />
          <Link href={`${storeShopPath(store.slug)}${filtersQuery({ category: listing.category })}`}>{listing.category}</Link>
          <Icon name="chevron" size={14} />
          <span aria-current="page">{listing.name}</span>
        </nav>

        <div className={styles.productLayout}>
          <div className={styles.galleryColumn}>
            <Gallery images={view.images} alt={listing.name} emoji={view.emoji} />
          </div>

          <div className={styles.details}>
            <h1>{listing.name}</h1>
            {(listing.seller_verified || sellerRating != null || deals > 0) && (
              <ul className={styles.proofLine} aria-label="The seller's record">
                {listing.seller_verified && (
                  <li className={styles.proofVerified}>
                    <Icon name="verified" size={15} /> Verified seller
                  </li>
                )}
                {sellerRating != null && (
                  <li>
                    <Icon name="star" size={14} className={styles.proofStar} /> {sellerRating.toFixed(1)}/5{' '}
                    <span className={styles.proofMuted}>({sellerReviews})</span>
                  </li>
                )}
                {deals > 0 && (
                  <li>
                    <Icon name="handshake" size={14} /> {plural(deals, 'deal')} done
                  </li>
                )}
              </ul>
            )}
            <div className={styles.priceRow}>
              <p className={styles.bigPrice}>
                <Price label={view.priceLabel} />
              </p>
              {stock && (
                <span className={`${styles.stockPill} ${stock.low ? styles.stockLow : ''}`}>{stock.label}</span>
              )}
            </div>
            {facts.length > 0 && (
              <ul className={styles.facts}>
                {facts.map((f) => (
                  <li key={f} className={styles.fact}>
                    {f}
                  </li>
                ))}
              </ul>
            )}
            {unavailable === 'gone' && (
              <p className={styles.unavailable} role="status">
                This product isn&apos;t available any more. <Link href={storeShopPath(store.slug)}>See what else {store.name} has.</Link>
              </p>
            )}
            {unavailable === 'out_of_stock' && (
              <p className={styles.unavailable} role="status" data-testid="out-of-stock">
                Out of stock at {store.name} right now.{' '}
                {webCommerce ? <Link href={askPath}>Ask the store when it&apos;s back.</Link> : null}
              </p>
            )}
            {unavailable === 'paused' && (
              <p className={styles.unavailable} role="status" data-testid="paused">
                {store.name} isn&apos;t taking orders for this product for now.{' '}
                {webCommerce ? <Link href={askPath}>Ask the store about it.</Link> : null}
              </p>
            )}

            {buyable && (
              // The bar a phone keeps at hand once this has scrolled away
              // (ProductStickyBar) watches it by its id.
              <div id="buy-box">
                <ProductBuyBox storeId={store.id} cartPath={cartPath} line={buyLine} />
              </div>
            )}
            <div className={shopStyles.payNote}>
              <Icon name="check" size={20} />
              <p>
                <strong>{SEE_FIRST.lead}</strong> {PAY_LINE} {NO_DEPOSIT}
              </p>
            </div>
            {view.available && <EscrowBox compact directory={escrow} />}

            {listing.description?.trim() && (
              <section className={shopStyles.descr} aria-labelledby="descr-title">
                <h2 id="descr-title">About this product</h2>
                <p className={styles.productText}>{listing.description.trim()}</p>
              </section>
            )}

            <div className={styles.cta}>
              {webCommerce ? (
                // A question needs no app: the conversation is on the website
                // (and in the app, for the store), and opens with this product.
                <Link href={askPath} className={`button button--ghost ${shopStyles.askButton}`} data-testid="ask-store">
                  <Icon name="chat" size={18} /> Ask {store.name} about this product
                </Link>
              ) : (
                view.available && (
                  <AppButton chat label="Chat with the seller or make an offer in the BROKA app" className={shopStyles.offerLink} />
                )
              )}
              <ShareButtons storeId={store.id} url={view.url} title={listing.name} />
            </div>

            <div className={`card ${styles.sellerCard}`} data-testid="seller-card">
              <div className={shopStyles.sellerHead}>
                <StoreAvatar name={store.name} logo={shop.logo && !shop.logo.startsWith('data:') ? shop.logo : null} size={44} />
                <h2>
                  <small>Sold by</small>
                  <Link href={shop.path}>{store.name}</Link>
                </h2>
                <Link href={storeShopPath(store.slug)} className={shopStyles.sellerShop}>
                  Visit store <Icon name="chevron" size={14} />
                </Link>
              </div>
              <TrustChips
                verified={listing.seller_verified}
                completedDeals={listing.seller_completed_deals}
                rating={listing.seller_rating}
                reviewCount={listing.seller_review_count ?? 0}
                dealTimeMinutes={listing.seller_avg_deal_time_minutes}
                memberSince={store.owner?.member_since}
              />
            </div>
          </div>
        </div>

        {more.length > 0 && (
          <section className={shopStyles.moreFrom} aria-labelledby="more-title">
            <div className={shopStyles.toolbar}>
              <h2 id="more-title">More from {store.name}</h2>
              <Link href={storeShopPath(store.slug)} className={shopStyles.seeAll}>
                See all <Icon name="chevron" size={14} />
              </Link>
            </div>
            <div className={shopStyles.grid}>
              {more.map((p) => (
                <ProductCard key={p.id} product={p} storeId={store.id} />
              ))}
            </div>
          </section>
        )}
        {buyable && (
          <ProductStickyBar storeId={store.id} cartPath={cartPath} line={buyLine} priceLabel={view.priceLabel} watch="buy-box" />
        )}
        <VisitBeacon storeId={store.id} via={via} campaign={campaign} productView />
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: jsonLdScript(productJsonLd(view, store.name)) }}
        />
      </main>
      <StoreFooter view={shop} />
      <CartDrawer storeId={store.id} storeName={store.name} cartPath={cartPath} />
    </StorefrontShell>
  )
}
