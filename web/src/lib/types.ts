// The shapes the BROKA API returns, as far as the storefront reads them.
// Mirrors backend/api/domains/stores/service.py (_store_dict) and
// backend/api/domains/listings/service.py (_listing_dict).

/** One stored image in three sizes (URLs, or paths on the API). */
export interface ImageSizes {
  id: string
  thumb: string
  medium: string
  large: string
  /** Set on a listing's cover: "showcase" or "photo". */
  kind?: string | null
}

export interface StoreOwner {
  verified: boolean
  rating: number | null
  completed_deals: number
  member_since: string | null
}

export interface Store {
  id: string
  name: string
  slug: string
  url: string
  category: string | null
  description: string | null
  country: string
  county: string | null
  subcounty: string | null
  location_description: string | null
  business_email: string | null
  business_email_verified: boolean
  logo: ImageSizes | null
  cover: ImageSizes | null
  photo_images: ImageSizes[]
  /** Legacy: an image URL, or base64 for a store not converted yet. */
  logo_url: string | null
  photos: string[]
  owner: StoreOwner | null
  is_active: boolean
  listing_count: number
}

export interface StoreCategory {
  name: string
  count: number
}

export interface Listing {
  id: string
  name: string
  category: string
  price: number
  status: string
  listing_type: string
  condition: string | null
  description: string | null
  location_name: string | null
  location_county: string | null
  location_subcounty: string | null
  photos: ImageSizes[]
  cover: ImageSizes | null
  /** Legacy base64 photos, comma-separated, for listings not converted yet. */
  verified_photos: string | null
  showcase_image_url: string | null
  seller_name: string | null
  seller_verified: boolean
  seller_rating: number | null
  seller_completed_deals: number
  store_id: string | null
  store_slug: string | null
  store_name: string | null
}

export type SortKey = 'featured' | 'newest' | 'price_low' | 'price_high'
