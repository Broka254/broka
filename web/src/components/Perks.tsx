// What buying from a store on BROKA means, in the strip shops put under
// their banner. Every line is true of every store: payment is held in
// escrow, it's by M-Pesa, and delivery or pickup is agreed in the deal. A
// verified seller gets a fourth.
import { Icon, type IconName } from './Icon'
import styles from './shop.module.css'

export function Perks({ verified }: { verified: boolean }) {
  const perks: Array<[IconName, string, string]> = [
    ['shield', 'Escrow protected', 'Paid only when you confirm delivery'],
    ['phone', 'Pay with M-Pesa', 'One prompt on your phone'],
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
