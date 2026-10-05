import { SITE_PAY_LINE } from '@/lib/safety'

import { HomeLink } from './HomeLink'
import styles from './SiteFooter.module.css'

export function SiteFooter() {
  return (
    <footer className={styles.footer}>
      <p>{SITE_PAY_LINE}</p>
      <p className={styles.small}>
        <HomeLink>BROKA</HomeLink> · Kenya&apos;s AI-brokered marketplace
      </p>
    </footer>
  )
}
