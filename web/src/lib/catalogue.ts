// What the storefront's catalogue shows: filters read from the URL, and the
// data a product card needs.
import { canonicalCategory, categoryVisual } from './categories'
import { formatPrice, placeLine } from './format'
import { resolveImage, resolveSizes, srcSet } from './images'
import { productPath } from './links'
import type { Listing, SortKey } from './types'

export const SORTS: ReadonlyArray<{ key: SortKey; label: string }> = [
  { key: 'featured', label: 'Recommended' },
  { key: 'newest', label: 'Newest' },
  { key: 'price_low', label: 'Price: low to high' },
  { key: 'price_high', label: 'Price: high to low' },
]

export interface CatalogueFilters {
  q: string
  category: string | null
  sort: SortKey
}

type RawParams = Record<string, string | string[] | undefined>

const first = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v)

/** The catalogue filters in a page's search params, validated. */
export function readFilters(params: RawParams): CatalogueFilters {
  const q = (first(params.q) ?? '').replace(/\s+/g, ' ').trim().slice(0, 100)
  const category = canonicalCategory(first(params.category))
  const sortRaw = first(params.sort)
  const sort = SORTS.some((s) => s.key === sortRaw) ? (sortRaw as SortKey) : 'featured'
  return { q, category, sort }
}

/** The query string for a set of filters (defaults left out). */
export function filtersQuery(f: Partial<CatalogueFilters>): string {
  const p = new URLSearchParams()
  if (f.q) p.set('q', f.q)
  if (f.category) p.set('category', f.category)
  if (f.sort && f.sort !== 'featured') p.set('sort', f.sort)
  const s = p.toString()
  return s ? `?${s}` : ''
}

export interface ProductCardData {
  id: string
  name: string
  priceLabel: string
  href: string
  image: string | null
  imageSrcSet: string | null
  emoji: string
  place: string | null
  isAuction: boolean
}

/** Everything a product card shows, with image URLs resolved against the API. */
export function toProductCard(listing: Listing, storeSlug: string, apiUrl: string): ProductCardData {
  const cover = resolveSizes(listing.cover ?? listing.photos?.[0] ?? null, apiUrl)
  const legacy = listing.verified_photos?.split(',')[0] ?? listing.showcase_image_url
  return {
    id: listing.id,
    name: listing.name,
    priceLabel: formatPrice(listing.price),
    href: productPath(storeSlug, listing.id),
    image: cover?.medium ?? resolveImage(legacy, apiUrl),
    imageSrcSet: cover ? srcSet(cover) : null,
    emoji: categoryVisual(listing.category).emoji,
    place: placeLine(listing.location_subcounty, listing.location_county) ?? listing.location_name,
    isAuction: listing.listing_type === 'auction',
  }
}
