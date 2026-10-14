import Image from 'next/image'

import { APP_DOWNLOAD_URL } from '@/lib/config'
import { asset } from '@/lib/links'

import { HomeLink } from './HomeLink'
import styles from './SiteHeader.module.css'

// The logo is unoptimized because /_next/image on broka.co.ke is the BROKA
// website's image service, which doesn't have the storefront's files.
export function SiteHeader() {
  return (
    <header className={styles.header}>
      <HomeLink className={styles.brand} aria-label="BROKA home">
        <Image src={asset('/logo.png')} unoptimized alt="" width={30} height={30} priority />
        <span className={styles.word}>BROKA</span>
      </HomeLink>
      <a className={styles.get} href={APP_DOWNLOAD_URL} rel="nofollow">
        Get the app
      </a>
    </header>
  )
}
