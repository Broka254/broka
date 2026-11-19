import { HomeLink } from '@/components/HomeLink'
import { Icon } from '@/components/Icon'
import { SiteHeader } from '@/components/SiteHeader'

import styles from './message.module.css'

export default function NotFound() {
  return (
    <>
      <SiteHeader />
      <main className={`page ${styles.main}`}>
        <span className={styles.mark} aria-hidden="true">
          <Icon name="search" size={32} />
        </span>
        <h1>Nothing here</h1>
        <p className="muted">This page doesn&apos;t exist, or it has moved.</p>
        <HomeLink className="button">Go to BROKA</HomeLink>
      </main>
    </>
  )
}
