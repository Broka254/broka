// "Pay with escrow" - the independent escrow services BROKA lists, where a
// buyer decides how to pay: the cart, the product page and the store's
// details (2026-10-08).
//
// BROKA holds no deal money for launch, and a store's buyer is often in
// another town, so the safe way to pay is an escrow service. The box is
// loud on purpose - escrow green, its own border - and it carries the rule
// a fake escrow site depends on breaking: open the service yourself, never
// from a link the store sends. Each link opens the service's own site, in a
// new tab, with no referrer and no ranking credit from BROKA (nofollow):
// it is a pointer, not an endorsement, and the notice says so.
//
// THE LIST IS THE API'S (lib/escrow-providers.ts), passed in by the page,
// which fetches it. It used to be a copy typed into lib/safety.ts. When the
// list could not be loaded, the box shows no providers and says so: a stale
// list of "where to send your money" is worse than none.
import { OPEN_IT_YOURSELF, ZENO_ESCROW } from '@/lib/safety'
import { UNAVAILABLE, type EscrowDirectory } from '@/lib/escrow-providers'

import { Icon } from './Icon'
import styles from './shop.module.css'

function site(url: string): string {
  return url.replace(/^https?:\/\/(www\.)?/, '').replace(/\/$/, '')
}

const LEAD =
  'Pay through an independent escrow service, under that service\u2019s own rules. They are not run by BROKA, and each is only as protective as its own terms say.'

export function EscrowBox({
  directory = UNAVAILABLE,
  compact = false,
}: {
  directory?: EscrowDirectory
  compact?: boolean
}) {
  const { providers, disclaimer, notices } = directory
  return (
    <section className={styles.escrowBox} aria-labelledby="escrow-title" data-testid="escrow-box">
      <h2 id="escrow-title" className={styles.escrowTitle}>
        <Icon name="shield" size={20} /> Pay with escrow
      </h2>
      <p className={styles.escrowLead}>{LEAD}</p>
      {providers.length > 0 ? (
        <ul className={styles.escrowList}>
          {providers.map((p) => (
            <li key={p.id}>
              <a href={p.url} target="_blank" rel="noopener noreferrer nofollow">
                <strong>{p.name}</strong> <span>{site(p.url)}</span>
              </a>
              {!compact && (
                <small>
                  {p.feeSummary}. {p.summary}
                  {p.notToBeConfusedWith ? ` ${p.notToBeConfusedWith}` : ''}
                </small>
              )}
              {p.warning && <small data-testid="escrow-warning">{p.warning}</small>}
            </li>
          ))}
        </ul>
      ) : (
        <p className={styles.escrowRule} data-testid="escrow-unavailable">
          <Icon name="info" size={16} /> The list of escrow services could not be loaded just now. Try again in a
          minute. Don&rsquo;t use an escrow link a seller sends you instead.
        </p>
      )}
      {notices.map((n) => (
        <p key={n} className={styles.escrowRule}>
          <Icon name="info" size={16} /> {n}
        </p>
      ))}
      <p className={styles.escrowRule}>
        <Icon name="info" size={16} /> {OPEN_IT_YOURSELF}
      </p>
      <p className={styles.escrowZeno}>{ZENO_ESCROW}</p>
      <p className={styles.escrowDisclaimer}>{disclaimer}</p>
    </section>
  )
}
