import { HomeLink } from '@/components/HomeLink'
import { Icon } from '@/components/Icon'
import { SiteHeader } from '@/components/SiteHeader'

import styles from '../../message.module.css'

export default function StoreNotFound() {
  return (
    <>
      <SiteHeader />
      <main className={`page ${styles.main}`}>
        <span className={styles.mark} aria-hidden="true">
          <Icon name="store" size={32} />
        </span>
        <h1>Store not found</h1>
        <p className="muted">
          There&apos;s no store at this link. Check the spelling, or ask the seller for their link again.
        </p>
        <HomeLink className="button">Go to BROKA</HomeLink>
      </main>
    </>
  )
}
