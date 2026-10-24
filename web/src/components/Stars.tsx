// The storefront's one star row: five outline stars with a fractional fill.
// `value` is star units 0-5 - a store's 0-10 score must pass through
// starsFromStoreScore first (lib/ratings.ts), or 6.5/10 would draw as 5/5.
import { starFraction } from '@/lib/ratings'

import styles from './store.module.css'

export function Stars({ value, label, size = 15 }: { value: number; label: string; size?: number }) {
  const filled = `${starFraction(value) * 100}%`
  return (
    <span className={styles.stars} role="img" aria-label={label} style={{ fontSize: size }}>
      <span aria-hidden="true">★★★★★</span>
      <span className={styles.starsFill} aria-hidden="true" style={{ width: filled }}>
        ★★★★★
      </span>
    </span>
  )
}
