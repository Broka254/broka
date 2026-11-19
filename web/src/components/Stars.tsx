// The storefront's one star row: five outline stars with a fractional fill.
// `value` is star units 0-5 - a store's 0-10 score must pass through
// starsFromStoreScore first (lib/ratings.ts), or 6.5/10 would draw as 5/5.
//
// Drawn, not typed: the ★ character came from whatever font a phone had,
// and some drew it as a box (STORES_UI_REVIEW.md L6). The row is one image
// to a screen reader, named by `label`.
import { starFraction } from '@/lib/ratings'

import styles from './store.module.css'

const STAR = 'm12 2.6 2.9 6 6.6.8-4.9 4.5 1.3 6.5L12 17.2l-5.9 3.2 1.3-6.5L2.5 9.4l6.6-.8z'

function Row({ size }: { size: number }) {
  return (
    <>
      {[0, 1, 2, 3, 4].map((i) => (
        <svg key={i} width={size} height={size} viewBox="0 0 24 24" aria-hidden="true" focusable="false">
          <path d={STAR} fill="currentColor" />
        </svg>
      ))}
    </>
  )
}

export function Stars({ value, label, size = 15 }: { value: number; label: string; size?: number }) {
  const filled = `${starFraction(value) * 100}%`
  return (
    <span className={styles.stars} role="img" aria-label={label} style={{ fontSize: size }}>
      <span className={styles.starsBase} aria-hidden="true">
        <Row size={size} />
      </span>
      <span className={styles.starsFill} aria-hidden="true" style={{ width: filled }}>
        <Row size={size} />
      </span>
    </span>
  )
}
