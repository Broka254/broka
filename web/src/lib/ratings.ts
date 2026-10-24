// The storefront's rating scales, in one place.
//
// A store's composite score is 0-10 (backend stores/rating.py); a buyer
// review is 1-5 stars. Passing the composite straight to a five-star
// renderer drew 6.5/10 as five filled stars, so every star row converts
// through starsFromStoreScore first and only ever receives star units.

export const buyerRatingMax = 5

/** A store's 0-10 score in star units: 6.5/10 is 3.25/5, never 5/5. */
export function starsFromStoreScore(score: number): number {
  if (Number.isNaN(score)) return 0
  return Math.min(Math.max(score, 0), 10) / 2
}

/** A buyer average clamped to the 1-5 scale it came from. */
export function buyerStars(value: number): number {
  if (Number.isNaN(value)) return 0
  return Math.min(Math.max(value, 0), buyerRatingMax)
}

/** How much of the star row to fill, 0-1. */
export function starFraction(value: number): number {
  return buyerStars(value) / buyerRatingMax
}

/** "1 review" / "12 reviews" for a buyer-review count. */
export function reviewCountLabel(count: number): string {
  return `${count} review${count === 1 ? '' : 's'}`
}

/**
 * "Usually replies in about 25 min" from the seller standing's measured
 * median. Null is unmeasured - never "fast".
 */
export function replyTimeLabel(minutes: number | null | undefined): string | null {
  if (minutes == null || Number.isNaN(minutes) || minutes < 0) return null
  if (minutes < 1) return 'Usually replies straight away'
  if (minutes < 60) return `Usually replies in about ${Math.round(minutes)} min`
  if (minutes < 1440) return `Usually replies in about ${(minutes / 60).toFixed(1)} h`
  return `Usually replies in about ${(minutes / 1440).toFixed(1)} days`
}

/** "20 Sep 2026" for a review's created_at, or null when it isn't a date. */
export function reviewDate(iso: string | null | undefined): string | null {
  if (!iso) return null
  // The API writes naive UTC timestamps (`2026-09-20T10:00:00`, no Z). A
  // bare string is parsed in the server's local zone, which can shift the
  // date across midnight; mark it UTC before parsing instead.
  const utc = /(?:Z|[+-]\d{2}:?\d{2})$/i.test(iso) ? iso : `${iso}Z`
  const date = new Date(utc)
  if (Number.isNaN(date.getTime())) return null
  return new Intl.DateTimeFormat('en-KE', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
    timeZone: 'UTC',
  }).format(date)
}
