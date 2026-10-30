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
  /** Who runs the store. Absent from API versions before "Store details". */
  name?: string | null
  verified: boolean
  /**
   * The owner's buyer-review average, 1-5. Null when nobody has reviewed
   * them - never the old account default of 5.0. This is the person's
   * record, not the shop's 0-10 composite score (`Store.rating`).
   */
  rating: number | null
  /** How many buyer reviews that average is over. 0 = no rating yet. */
  review_count?: number | null
  completed_deals: number
  member_since: string | null
  /** A heartbeat in the last five minutes (API versions before it: absent). */
  online?: boolean
  /** "Active 3h ago"; null when the owner has never been seen. */
  last_active?: string | null
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
  /**
   * The STORE's own rating, 0-10 (backend stores/rating.py): its reviews,
   * its reply time on its own products, and its tenure. Deliberately
   * separate from `owner.rating`, which is the person's seller record.
   * Absent from API versions before the store rating shipped.
   */
  rating?: number | null
  /** How many reviews that rating counts. 0 means "no reviews yet". */
  review_count?: number | null
  /** Measured average reply time in minutes; null = not measured. */
  response_minutes?: number | null
  created_at?: string | null
  /**
   * "physical" (premises a customer can visit) or "virtual" (online only).
   * Absent from API versions before store types: every store that existed
   * then was physical.
   */
  store_type?: 'physical' | 'virtual' | null
  /** Where it delivers: Kenyan counties, or ["Nationwide"]. */
  service_areas?: string[] | null
  /** How buyers get their order, in the owner's words. */
  delivery_note?: string | null
  /** The weekly schedule, or null when the owner gave none. */
  opening_hours?: Record<string, OpeningHoursDay | null> | null
  opening_hours_week?: OpeningHoursWeekRow[] | null
  opening_hours_available?: boolean
  open_status?: OpenStatus | null
  /** Time before the store goes offline, for every reader (older APIs: absent). */
  paid_until?: string | null
  time_left?: TimeLeft | null
  time_left_label?: string | null
}

export interface OpeningHoursDay {
  /** A whole-day schedule carries only this. */
  all_day?: boolean
  /** "HH:MM", 24-hour. A close at or before open crosses midnight. */
  open?: string
  close?: string
}

export interface OpeningHoursWeekRow {
  day: string
  label: string
  short: string
  hours: string
  closed: boolean
  all_day: boolean
}

export interface OpenStatus {
  state: 'open' | 'closed' | 'unknown'
  label: string
  opens_at: string | null
  closes_at: string | null
  next_day: string | null
}

export interface StoreCategory {
  name: string
  count: number
}

/** Server-computed time before a listing/store goes offline. */
export interface TimeLeft {
  status: 'unlimited' | 'live' | 'ending' | 'unpaid' | 'expired' | 'store_covered'
  label: string
  seconds_left: number | null
  days_left: number | null
  goes_offline_at: string | null
  is_expiring_soon: boolean
}

export interface Listing {
  id: string
  name: string
  category: string
  price: number
  /** What one unit of `price` is ("bag"); null when it's for the whole item. */
  price_unit?: string | null
  /** How many the seller has for sale; null reads as one. */
  quantity?: number | null
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
  /** The seller's buyer-review average, 1-5; null when nobody reviewed them. */
  seller_rating: number | null
  /** How many buyer reviews `seller_rating` is over (older APIs: absent). */
  seller_review_count?: number | null
  seller_completed_deals: number
  /**
   * The seller's average deal time, agreement to payout, in minutes - on the
   * single-listing read only, and only once they have completed a deal.
   */
  seller_avg_deal_time_minutes?: number | null
  /** Whether a buyer can still buy it (single-listing read): not sold out or removed. */
  available?: boolean
  store_id: string | null
  store_slug: string | null
  store_name: string | null
  /** Paid time's end and the server's countdown to it (older APIs: absent). */
  paid_until?: string | null
  time_left?: TimeLeft | null
  time_left_label?: string | null
}

/** The buyer-review figures for one store (GET /stores/{id}/reviews). */
export interface ReviewSummary {
  /** 1-5, one decimal; null when `count` is zero. */
  avg: number | null
  count: number
  /** Keyed "1".."5"; every key is present. */
  distribution: Record<string, number>
}

/** A public review card. The API sends no reviewer, deal or seller id. */
export interface PublicReview {
  id: string
  /** 1-5. */
  rating: number
  comment: string | null
  created_at: string | null
  /** A display name such as "Amina W."; null if the buyer has none. */
  reviewer_name: string | null
}

/**
 * The owner's separate 0-10 trust snapshot (backend trust/public_standing.py).
 * Not the shop's composite score and not the 1-5 buyer-review average.
 */
export interface SellerStanding {
  overall_rating: number | null
  dcr: number | null
  dcr_provisional: boolean
  median_response_minutes: number | null
  completed_deals: number
  as_of: string | null
}

/** The store's buyer reviews, plus the owner's seller standing. */
export interface StoreReviews {
  summary: ReviewSummary
  reviews: PublicReview[]
  seller_standing?: SellerStanding | null
  /** Present only for a signed-in caller; the storefront is anonymous. */
  viewer?: {
    can_review: boolean
    already_reviewed: boolean
    reviewable_deals: unknown[]
  } | null
}

export type SortKey = 'featured' | 'newest' | 'price_low' | 'price_high'

export type ConditionKey = 'new' | 'used' | 'refurbished'

export type PriceBandKey = 'under1k' | 'to5k' | 'to20k' | 'to100k' | 'over100k'
