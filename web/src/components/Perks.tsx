// What buying from a store on BROKA means, in the strip shops put under
// their banner. Every line is true of every store: you see the item before
// you pay, you pay the store directly (BROKA doesn't hold payments for now:
// lib/safety.ts), and delivery or pickup is agreed with the store. A
// verified seller gets a fourth.
import { PERK_PAY_DIRECT, PERK_SEE_FIRST } from '@/lib/safety'

import { Icon, type IconName } from './Icon'
import styles from './shop.module.css'

export function Perks({ verified }: { verified: boolean }) {
  const perks: Array<[IconName, string, string]> = [
    ['check', PERK_SEE_FIRST.title, PERK_SEE_FIRST.sub],
    ['phone', PERK_PAY_DIRECT.title, PERK_PAY_DIRECT.sub],
    ['truck', 'Delivery or pickup', 'Agreed with the store'],
  ]
  if (verified) perks.push(['verified', 'Verified seller', 'Holds the BROKA Verified badge'])
  return (
    <ul className={styles.perks} aria-label="Buying from this store">
      {perks.map(([icon, title, sub]) => (
        <li key={title} className={icon === 'verified' ? styles.perkVerified : undefined}>
          <span className={styles.perkIcon}>
            <Icon name={icon} size={20} />
          </span>
          <span>
            <strong>{title}</strong>
            <small>{sub}</small>
          </span>
        </li>
      ))}
    </ul>
  )
}
