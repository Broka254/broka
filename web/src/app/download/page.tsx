import type { Metadata } from 'next'
import Image from 'next/image'

import { APP_DOWNLOAD_URL } from '@/lib/config'
import { asset } from '@/lib/links'

import styles from './download.module.css'

export const metadata: Metadata = {
  title: 'Get the BROKA app',
  description: 'Take Kenya’s AI-brokered marketplace with you. Browse stores and talk through deals with Zeno in the BROKA app.',
  alternates: { canonical: '/download' },
}

export default function DownloadPage() {
  return (
    <main className={styles.page}>
      <a href="https://broka.co.ke" className={styles.brand} aria-label="BROKA home">
        <Image src={asset('/logo.png')} alt="" width={54} height={54} unoptimized priority />
        <span>BROKA</span>
      </a>
      <section className={styles.card} aria-labelledby="download-title">
        <p className={styles.kicker}>BROKA, wherever you go</p>
        <h1 id="download-title">A better way to buy and sell in Kenya.</h1>
        <p className={styles.lead}>
          Browse independent stores, ask questions, and carry the conversation through to a deal with Zeno, BROKA&apos;s AI broker.
        </p>
        <ul className={styles.features}>
          <li><span aria-hidden="true">01</span><div><strong>Explore real stores</strong><small>Find products and browse sellers across Kenya.</small></div></li>
          <li><span aria-hidden="true">02</span><div><strong>Talk it through</strong><small>Keep questions and offers moving with Zeno.</small></div></li>
          <li><span aria-hidden="true">03</span><div><strong>Make your deal</strong><small>Agree the details directly with the store.</small></div></li>
        </ul>
        <a href={APP_DOWNLOAD_URL} rel="nofollow" className={styles.download}>
          Download BROKA for Android <span aria-hidden="true">↗</span>
        </a>
        <p className={styles.note}>Android app download · APK</p>
      </section>
      <a href="https://broka.co.ke" className={styles.back}>← Back to BROKA</a>
    </main>
  )
}
