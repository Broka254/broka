// "Pay with escrow" - Kenya's independent escrow services, where a buyer
// decides how to pay: the cart, the product page and the store's details
// (2026-10-08).
//
// BROKA holds no deal money for launch, and a store's buyer is often in
// another town, so the safe way to pay is an escrow service. The box is
// loud on purpose - escrow green, its own border - and it carries the rule
// a fake escrow site depends on breaking: open the service yourself, never
// from a link the store sends. Each link opens the service's own site, in a
// new tab, with no referrer and no ranking credit from BROKA (nofollow):
// it is a pointer, not an endorsement, and the disclaimer says so.
import {
  ESCROW_DISCLAIMER,
  ESCROW_PROVIDERS,
  ESCROW_SERVICES,
  OPEN_IT_YOURSELF,
  ZENO_ESCROW,
} from '@/lib/safety'

import { Icon } from './Icon'
import styles from './shop.module.css'

function site(url: string): string {
  return url.replace(/^https?:\/\/(www\.)?/, '').replace(/\/$/, '')
}

export function EscrowBox({ compact = false }: { compact?: boolean }) {
  return (
    <section className={styles.escrowBox} aria-labelledby="escrow-title" data-testid="escrow-box">
      <h2 id="escrow-title" className={styles.escrowTitle}>
        <Icon name="shield" size={20} /> Pay with escrow
      </h2>
      <p className={styles.escrowLead}>{ESCROW_SERVICES.text}</p>
      <ul className={styles.escrowList}>
        {ESCROW_PROVIDERS.map((p) => (
          <li key={p.url}>
            <a href={p.url} target="_blank" rel="noopener noreferrer nofollow">
              <strong>{p.name}</strong> <span>{site(p.url)}</span>
            </a>
            {!compact && <small>{p.note}</small>}
          </li>
        ))}
      </ul>
      <p className={styles.escrowRule}>
        <Icon name="info" size={16} /> {OPEN_IT_YOURSELF}
      </p>
      <p className={styles.escrowZeno}>{ZENO_ESCROW}</p>
      <p className={styles.escrowDisclaimer}>{ESCROW_DISCLAIMER}</p>
    </section>
  )
}
