// Server-side view data for the store and product pages: images resolved
// against the API, link previews, and structured data for search engines.
import 'server-only'

import { categoryVisual } from './categories'
import { clip, formatUnitPrice, placeLine, plural } from './format'
import { type ResolvedSizes, resolveImage, resolveSizes, srcSet } from './images'
import { DEFAULT_PREVIEW_IMAGE, absoluteUrl, previewImageUrl, productPath, storePath } from './links'
import { API_URL } from './server-config'
import type { Listing, Store } from './types'

export interface StoreView {
  store: Store
  path: string
  url: string
  place: string | null
  cover: { src: string; srcSet: string | null } | null
  /** Every picture of the shop, cover first, for "Store details". */
  photos: Array<{ src: string; thumb: string }>
  logo: string | null
  initial: string
  gradient: readonly string[]
  description: string
}

export function storeView(store: Store): StoreView {
  const coverSizes: ResolvedSizes | null =
    resolveSizes(store.cover, API_URL) ?? resolveSizes(store.photo_images?.[0], API_URL)
  const legacyCover = resolveImage(store.photos?.[0], API_URL)
  const sized = [store.cover, ...(store.photo_images ?? [])]
    .map((p) => resolveSizes(p, API_URL))
    .filter((p): p is ResolvedSizes => p !== null)
  const legacy = (store.photos ?? [])
    .map((p) => resolveImage(p, API_URL))
    .filter((p): p is string => Boolean(p))
  // Old rows keep their photos as plain strings until the media backfill
  // converts them; they count when there are no stored shop photos.
  const photos = [
    ...sized.map((p) => ({ src: p.large, thumb: p.medium })),
    ...((store.photo_images ?? []).length ? [] : legacy.map((src) => ({ src, thumb: src }))),
  ]
  const path = storePath(store.slug)
  return {
    store,
    path,
    url: absoluteUrl(path),
    place: placeLine(store.location_description, store.subcounty, store.county),
    cover: coverSizes
      ? { src: coverSizes.large, srcSet: srcSet(coverSizes) }
      : legacyCover
        ? { src: legacyCover, srcSet: null }
        : null,
    photos,
    logo: resolveSizes(store.logo, API_URL)?.medium ?? resolveImage(store.logo_url, API_URL),
    initial: (Array.from(store.name.trim())[0] ?? '?').toUpperCase(),
    gradient: categoryVisual(store.category).gradient,
    description: store.description?.trim() ?? '',
  }
}

/** The page's link-preview image: a JPEG made from the store's cover (or a
 *  shop photo, or the logo), else BROKA's default card. */
export function storePreviewImage(store: Store) {
  const id = store.cover?.id ?? store.photo_images?.[0]?.id ?? store.logo?.id
  return id
    ? { url: previewImageUrl(id), width: 1200, height: 630, type: 'image/jpeg' }
    : { url: DEFAULT_PREVIEW_IMAGE, width: 1200, height: 630, type: 'image/jpeg' }
}

export function storeDescription(store: Store): string {
  if (store.description?.trim()) return clip(store.description)
  const where = placeLine(store.subcounty, store.county)
  return [
    store.category ? `${store.category} store` : 'Store',
    where ? `in ${where}` : null,
    `· ${plural(store.listing_count, 'product')} on BROKA, every purchase protected.`,
  ]
    .filter(Boolean)
    .join(' ')
}

/** schema.org Store, for search engines. */
export function storeJsonLd(view: StoreView) {
  const { store } = view
  return {
    '@context': 'https://schema.org',
    '@type': 'Store',
    name: store.name,
    url: view.url,
    description: storeDescription(store),
    image: view.cover?.src.startsWith('http') ? view.cover.src : undefined,
    logo: view.logo?.startsWith('http') ? view.logo : undefined,
    address: {
      '@type': 'PostalAddress',
      addressCountry: 'KE',
      addressRegion: store.county ?? undefined,
      addressLocality: store.subcounty ?? undefined,
      streetAddress: store.location_description ?? undefined,
    },
  }
}

export interface ProductView {
  listing: Listing
  path: string
  url: string
  available: boolean
  priceLabel: string
  images: Array<{ src: string; srcSet?: string; thumb: string }>
  emoji: string
  place: string | null
}

export function productView(listing: Listing, storeSlug: string): ProductView {
  const sized = (listing.photos ?? [])
    .map((p) => resolveSizes(p, API_URL))
    .filter((p): p is ResolvedSizes => p !== null)
  let images: ProductView['images'] = sized.map((p) => ({ src: p.large, srcSet: srcSet(p), thumb: p.thumb }))
  if (!images.length) {
    // Rows not converted to stored images yet: base64 photos, or the cover.
    const legacy = (listing.verified_photos ?? '')
      .split(',')
      .map((b) => resolveImage(b, API_URL))
      .filter((s): s is string => Boolean(s))
    images = legacy.map((src) => ({ src, thumb: src }))
    const cover = resolveSizes(listing.cover, API_URL)
    if (!images.length && cover) images = [{ src: cover.large, srcSet: srcSet(cover), thumb: cover.thumb }]
  }
  const path = productPath(storeSlug, listing.id)
  return {
    listing,
    path,
    url: absoluteUrl(path),
    // The single-listing read also says when every unit is sold or in a
    // deal while the listing is still active - stock catches up within minutes.
    available: listing.status === 'active' && listing.available !== false,
    priceLabel: formatUnitPrice(listing.price, listing.price_unit),
    images,
    emoji: categoryVisual(listing.category).emoji,
    place: placeLine(listing.location_subcounty, listing.location_county) ?? listing.location_name,
  }
}

export function productPreviewImage(listing: Listing) {
  const id = listing.cover?.id ?? listing.photos?.[0]?.id
  return id
    ? { url: previewImageUrl(id), width: 1200, height: 630, type: 'image/jpeg' }
    : { url: DEFAULT_PREVIEW_IMAGE, width: 1200, height: 630, type: 'image/jpeg' }
}

/** schema.org Product with its offer, for search engines. */
export function productJsonLd(view: ProductView, storeName: string) {
  const { listing } = view
  const image = view.images.map((i) => i.src).filter((s) => s.startsWith('http'))
  return {
    '@context': 'https://schema.org',
    '@type': 'Product',
    name: listing.name,
    description: listing.description ? clip(listing.description, 500) : undefined,
    image: image.length ? image : undefined,
    category: listing.category,
    offers: {
      '@type': 'Offer',
      url: view.url,
      priceCurrency: 'KES',
      price: Math.round(listing.price),
      availability: view.available ? 'https://schema.org/InStock' : 'https://schema.org/SoldOut',
      seller: { '@type': 'Organization', name: storeName },
    },
  }
}

/** JSON for a <script type="application/ld+json">, safe inside HTML. */
export function jsonLdScript(data: unknown): string {
  return JSON.stringify(data).replace(/</g, '\\u003c')
}
