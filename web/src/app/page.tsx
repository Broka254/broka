import Image from 'next/image'

import { SiteFooter } from '@/components/SiteFooter'
import { SiteHeader } from '@/components/SiteHeader'
import { APP_DOWNLOAD_URL } from '@/lib/config'
import { asset } from '@/lib/links'

import styles from './home.module.css'

export default function Home() {
  return (
    <>
      <SiteHeader />
      <main className={`page ${styles.main}`}>
        <Image src={asset('/logo.png')} unoptimized alt="" width={120} height={120} priority className={styles.mark} />
        <h1 className={styles.title}>Buy and sell with confidence</h1>
        <p className={styles.lead}>
          BROKA is Kenya&apos;s AI-brokered marketplace. Zeno negotiates for you, and your money is
          held safely until you&apos;ve received what you paid for.
        </p>
        <a className="button" href={APP_DOWNLOAD_URL} rel="nofollow">
          Get the BROKA app
        </a>
        <p className={styles.note}>
          Have a store link? Open it to shop that store right here in your browser.
        </p>
      </main>
      <SiteFooter />
    </>
  )
}
