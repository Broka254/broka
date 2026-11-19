import { formatDealTime, plural, yearOf } from '@/lib/format'

import { Icon, type IconName } from './Icon'
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
  // Inline SVG, not emoji (🤝, 📅 drew differently on every phone and
  // looked unfinished: STORES_UI_REVIEW.md L6).
  const chips: Array<{ key: string; icon: IconName; text: string; tone?: string }> = []
  if (verified) chips.push({ key: 'v', icon: 'verified', text: 'Verified seller', tone: styles.good })
  if (completedDeals > 0) {
    chips.push({ key: 'd', icon: 'handshake', text: `${plural(completedDeals, 'deal')} done` })
    if (dealTimeMinutes != null) {
      chips.push({ key: 't', icon: 'clock', text: `Deals take ${formatDealTime(dealTimeMinutes)}` })
    }
  }
  // Reviews, not deals, make an average: many deals with no reviews is no
  // rating, not a perfect one. The "/5" keeps it apart from the shop's
  // 0-10 composite on its pages.
  if (reviews > 0 && rating != null) {
    chips.push({ key: 'r', icon: 'star', text: `${rating.toFixed(1)}/5 (${reviews})`, tone: styles.star })
  }
  if (since) chips.push({ key: 's', icon: 'calendar', text: `On BROKA since ${since}` })
  if (!chips.length) return null
  return (
    <ul className={styles.chips} aria-label="About this seller">
      {chips.map((c) => (
        <li key={c.key} className={styles.chip}>
          <Icon name={c.icon} size={14} className={c.tone ?? styles.chipIcon} />
          {c.text}
        </li>
      ))}
    </ul>
  )
}
