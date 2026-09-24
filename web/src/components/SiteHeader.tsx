import Image from 'next/image'
import Link from 'next/link'

import { APP_DOWNLOAD_URL } from '@/lib/config'

import styles from './SiteHeader.module.css'

export function SiteHeader() {
  return (
    <header className={styles.header}>
      <Link href="/" className={styles.brand} aria-label="BROKA home">
        <Image src="/logo.png" alt="" width={30} height={30} priority />
        <span className={styles.word}>BROKA</span>
      </Link>
      <a className={styles.get} href={APP_DOWNLOAD_URL} rel="nofollow">
        Get the app
      </a>
    </header>
  )
}
