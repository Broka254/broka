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
import { Gallery } from '@/components/Gallery'
import { Icon } from '@/components/Icon'
import { ProductBuyBox } from '@/components/ProductBuyBox'
import { ProductCard } from '@/components/ProductCard'
import { ShareButtons } from '@/components/ShareButtons'
import { StoreFooter } from '@/components/StoreFooter'
import { StoreHeader } from '@/components/StoreHeader'
import { TrustChips } from '@/components/TrustChips'
import { VisitBeacon } from '@/components/VisitBeacon'
import shopStyles from '@/components/shop.module.css'
import styles from '@/components/store.module.css'
import { getListing, getStore, getStoreListings } from '@/lib/api'
import { filtersQuery, toProductCard } from '@/lib/catalogue'
import { clip, conditionLabel, formatPrice } from '@/lib/format'
import { productPath, storeCartPath, storePath, viaTag } from '@/lib/links'
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
  if (name !== store.slug) {
    permanentRedirect(`${productPath(store.slug, listing.id)}${via ? `?via=${via}` : ''}`)
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

  return (
    <>
      <StoreHeader view={shop} />
      <main className={`page ${shopStyles.storePage}`}>
        <nav aria-label="Breadcrumb" className={shopStyles.crumbs}>
          <Link href={shop.path}>{store.name}</Link>
          <Icon name="chevron" size={14} />
          <Link href={`${shop.path}${filtersQuery({ category: listing.category })}`}>{listing.category}</Link>
          <Icon name="chevron" size={14} />
          <span aria-current="page">{listing.name}</span>
        </nav>

        <div className={styles.productLayout}>
          <Gallery images={view.images} alt={listing.name} emoji={view.emoji} />

          <div className={styles.details}>
            <h1>{listing.name}</h1>
            <p className={styles.bigPrice}>{view.priceLabel}</p>
            {facts.length > 0 && (
              <ul className={styles.facts}>
                {facts.map((f) => (
                  <li key={f} className={styles.fact}>
                    {f}
                  </li>
                ))}
              </ul>
            )}
            {!view.available && (
              <p className={styles.unavailable} role="status">
                This product isn&apos;t available any more. <Link href={shop.path}>See what else {store.name} has.</Link>
              </p>
            )}

            {view.available && listing.listing_type !== 'auction' && (
              <ProductBuyBox
                storeId={store.id}
                cartPath={cartPath}
                line={{
                  id: card.id,
                  name: card.name,
                  price: card.price,
                  unit: card.unit,
                  image: card.image,
                  emoji: card.emoji,
                  href: card.href,
                  max: card.maxQuantity,
                }}
              />
            )}
            <div className={shopStyles.payNote}>
              <Icon name="check" size={22} />
              <p>
                <strong>{SEE_FIRST.lead}</strong> {PAY_LINE} {NO_DEPOSIT}
              </p>
            </div>

            {listing.description?.trim() && (
              <section className={shopStyles.descr} aria-labelledby="descr-title">
                <h2 id="descr-title">About this product</h2>
                <p className={styles.productText}>{listing.description.trim()}</p>
              </section>
            )}

            <div className={styles.cta}>
              {view.available && <AppButton label="Make an offer in the BROKA app" className={shopStyles.offerLink} />}
              <ShareButtons storeId={store.id} url={view.url} title={listing.name} />
            </div>

            <div className={`card ${styles.sellerCard}`}>
              <h2>
                Sold by <Link href={shop.path}>{store.name}</Link>
              </h2>
              <TrustChips
                verified={listing.seller_verified}
                completedDeals={listing.seller_completed_deals}
                rating={listing.seller_rating}
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
              <Link href={shop.path} className={shopStyles.seeAll}>
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
        <VisitBeacon storeId={store.id} via={via} />
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: jsonLdScript(productJsonLd(view, store.name)) }}
        />
      </main>
      <StoreFooter view={shop} />
      <CartDrawer storeId={store.id} storeName={store.name} cartPath={cartPath} />
    </>
  )
}
