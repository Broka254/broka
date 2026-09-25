// One product in a store: https://broka.co.ke/store/<name>/p/<id>.
// Buying happens in the BROKA app for now (checkout on the web comes with
// orders); this page is what a shared product link opens.
import type { Metadata } from 'next'
import Link from 'next/link'
import { notFound, permanentRedirect, redirect } from 'next/navigation'

import { AppButton } from '@/components/AppButton'
import { Gallery } from '@/components/Gallery'
import { ShareButtons } from '@/components/ShareButtons'
import { SiteFooter } from '@/components/SiteFooter'
import { SiteHeader } from '@/components/SiteHeader'
import { TrustChips } from '@/components/TrustChips'
import { VisitBeacon } from '@/components/VisitBeacon'
import styles from '@/components/store.module.css'
import { getListing, getStore } from '@/lib/api'
import { clip, conditionLabel, formatPrice } from '@/lib/format'
import { productPath, storePath, viaTag } from '@/lib/links'
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

  return (
    <>
      <SiteHeader />
      <main className="page">
        <Link href={shop.path} className={styles.back}>
          <span className={styles.backLogo}>
            {shop.logo ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={shop.logo} alt="" />
            ) : (
              <span aria-hidden="true">{shop.initial}</span>
            )}
          </span>
          ← More from {store.name}
        </Link>

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
            {listing.description?.trim() && <p className={styles.productText}>{listing.description.trim()}</p>}

            <div className={styles.cta}>
              {view.available && <AppButton label="Make an offer in the BROKA app" />}
              <p className={styles.ctaNote}>
                Pay through BROKA and your money is held safely until you confirm you&apos;ve received the item.
              </p>
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
                memberSince={store.owner?.member_since}
              />
            </div>
          </div>
        </div>
        <VisitBeacon storeId={store.id} via={via} />
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: jsonLdScript(productJsonLd(view, store.name)) }}
        />
      </main>
      <SiteFooter />
    </>
  )
}
