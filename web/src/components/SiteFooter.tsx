import { HomeLink } from './HomeLink'
import styles from './SiteFooter.module.css'

export function SiteFooter() {
  return (
    <footer className={styles.footer}>
      <p>
        Every purchase on BROKA is protected: your money is held safely until you confirm you
        received what you paid for.
      </p>
      <p className={styles.small}>
        <HomeLink>BROKA</HomeLink> · Kenya&apos;s AI-brokered marketplace
      </p>
    </footer>
  )
}
