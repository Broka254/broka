import { formatDealTime, plural, yearOf } from '@/lib/format'

import styles from './store.module.css'

/** The seller's real record: verified, completed deals, rating, deal time, since. */
export function TrustChips({
  verified,
  completedDeals,
  rating,
  reviewCount = 0,
  dealTimeMinutes,
  memberSince,
}: {
  verified: boolean
  completedDeals: number
  rating: number | null
  /** Buyer reviews behind `rating`; 0 means there is no average to show. */
  reviewCount?: number | null
  /** Average from agreement to payout; the app shows the same figure. */
  dealTimeMinutes?: number | null
  memberSince?: string | null
}) {
  const since = yearOf(memberSince)
  const reviews = reviewCount ?? 0
  const chips: Array<{ key: string; icon: string; text: string; tone?: string }> = []
  if (verified) chips.push({ key: 'v', icon: '✓', text: 'Verified seller', tone: styles.good })
  if (completedDeals > 0) {
    chips.push({ key: 'd', icon: '🤝', text: `${plural(completedDeals, 'deal')} done` })
    if (dealTimeMinutes != null) {
      chips.push({ key: 't', icon: '⏱', text: `Deals take ${formatDealTime(dealTimeMinutes)}` })
    }
  }
  // Reviews, not deals, make an average: many deals with no reviews is no
  // rating, not a perfect one. The "/5" keeps it apart from the shop's
  // 0-10 composite on its pages.
  if (reviews > 0 && rating != null) {
    chips.push({ key: 'r', icon: '★', text: `${rating.toFixed(1)}/5 (${reviews})`, tone: styles.star })
  }
  if (since) chips.push({ key: 's', icon: '📅', text: `On BROKA since ${since}` })
  if (!chips.length) return null
  return (
    <ul className={styles.chips} aria-label="About this seller">
      {chips.map((c) => (
        <li key={c.key} className={styles.chip}>
          <span className={c.tone} aria-hidden="true">
            {c.icon}
          </span>
          {c.text}
        </li>
      ))}
    </ul>
  )
}
