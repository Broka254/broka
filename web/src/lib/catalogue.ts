// What the storefront's catalogue shows: filters read from the URL, and the
// data a product card needs.
import { canonicalCategory, categoryVisual } from './categories'
import { conditionLabel, formatUnitPrice, placeLine } from './format'
import { resolveImage, resolveSizes, srcSet } from './images'
import { productPath } from './links'
import type { ConditionKey, Listing, PriceBandKey, SortKey } from './types'

export const SORTS: ReadonlyArray<{ key: SortKey; label: string }> = [
  { key: 'featured', label: 'Recommended' },
  { key: 'newest', label: 'Newest' },
  { key: 'price_low', label: 'Price: low to high' },
  { key: 'price_high', label: 'Price: high to low' },
]

export const CONDITIONS: ReadonlyArray<{ key: ConditionKey; label: string }> = [
  { key: 'new', label: 'New' },
  { key: 'used', label: 'Used' },
  { key: 'refurbished', label: 'Refurbished' },
]

/** The price filter's bands, as the app's (StorePriceBand): KES from and to. */
export const PRICE_BANDS: ReadonlyArray<{ key: PriceBandKey; label: string; min: number | null; max: number | null }> = [
  { key: 'under1k', label: 'Under 1K', min: null, max: 1000 },
  { key: 'to5k', label: '1K – 5K', min: 1000, max: 5000 },
  { key: 'to20k', label: '5K – 20K', min: 5000, max: 20000 },
  { key: 'to100k', label: '20K – 100K', min: 20000, max: 100000 },
  { key: 'over100k', label: '100K+', min: 100000, max: null },
]

export interface CatalogueFilters {
  q: string
  category: string | null
  sort: SortKey
  condition?: ConditionKey | null
  price?: PriceBandKey | null
}

/** Whether the filter panel narrows or reorders anything (search and category aside). */
export function panelActive(f: CatalogueFilters): boolean {
  return f.sort !== 'featured' || Boolean(f.condition) || Boolean(f.price)
}

type RawParams = Record<string, string | string[] | undefined>

const first = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v)

/** The catalogue filters in a page's search params, validated. */
export function readFilters(params: RawParams): CatalogueFilters {
  const q = (first(params.q) ?? '').replace(/\s+/g, ' ').trim().slice(0, 100)
  const category = canonicalCategory(first(params.category))
  const sortRaw = first(params.sort)
  const sort = SORTS.some((s) => s.key === sortRaw) ? (sortRaw as SortKey) : 'featured'
  const conditionRaw = first(params.condition)
  const condition = CONDITIONS.some((c) => c.key === conditionRaw) ? (conditionRaw as ConditionKey) : null
  const priceRaw = first(params.price)
  const price = PRICE_BANDS.some((b) => b.key === priceRaw) ? (priceRaw as PriceBandKey) : null
  return { q, category, sort, condition, price }
}

/** The query string for a set of filters (defaults left out). */
export function filtersQuery(f: Partial<CatalogueFilters>): string {
  const p = new URLSearchParams()
  if (f.q) p.set('q', f.q)
  if (f.category) p.set('category', f.category)
  if (f.sort && f.sort !== 'featured') p.set('sort', f.sort)
  if (f.condition) p.set('condition', f.condition)
  if (f.price) p.set('price', f.price)
  const s = p.toString()
  return s ? `?${s}` : ''
}

export interface ProductCardData {
  id: string
  name: string
  /** One unit's price, for the cart's totals. */
  price: number
  unit: string | null
  priceLabel: string
  href: string
  image: string | null
  imageSrcSet: string | null
  emoji: string
  place: string | null
  isAuction: boolean
  /** "New", "Used", "Refurbished", or null when the seller didn't say. */
  condition: string | null
  /** How many can go in a cart: the listing's stock, one for a single item. */
  maxQuantity: number
}

/** Everything a product card shows, with image URLs resolved against the API. */
export function toProductCard(listing: Listing, storeSlug: string, apiUrl: string): ProductCardData {
  const cover = resolveSizes(listing.cover ?? listing.photos?.[0] ?? null, apiUrl)
  const legacy = listing.verified_photos?.split(',')[0] ?? listing.showcase_image_url
  return {
    id: listing.id,
    name: listing.name,
    price: listing.price,
    unit: listing.price_unit ?? null,
    priceLabel: formatUnitPrice(listing.price, listing.price_unit),
    href: productPath(storeSlug, listing.id),
    image: cover?.medium ?? resolveImage(legacy, apiUrl),
    imageSrcSet: cover ? srcSet(cover) : null,
    emoji: categoryVisual(listing.category).emoji,
    place: placeLine(listing.location_subcounty, listing.location_county) ?? listing.location_name,
    isAuction: listing.listing_type === 'auction',
    condition: conditionLabel(listing.condition),
    maxQuantity: Math.max(1, Math.floor(listing.quantity ?? 1)),
  }
}
