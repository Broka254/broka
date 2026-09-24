import { plural, yearOf } from '@/lib/format'

import styles from './store.module.css'

/** The seller's real record: verified, completed deals, rating, since. */
export function TrustChips({
  verified,
  completedDeals,
  rating,
  memberSince,
}: {
  verified: boolean
  completedDeals: number
  rating: number | null
  memberSince?: string | null
}) {
  const since = yearOf(memberSince)
  const chips: Array<{ key: string; icon: string; text: string; tone?: string }> = []
  if (verified) chips.push({ key: 'v', icon: '✓', text: 'Verified seller', tone: styles.good })
  if (completedDeals > 0) {
    chips.push({ key: 'd', icon: '🤝', text: `${plural(completedDeals, 'deal')} done` })
    // A rating only means something once there are deals behind it.
    if (rating != null) chips.push({ key: 'r', icon: '★', text: rating.toFixed(1), tone: styles.star })
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
