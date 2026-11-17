// The documents a new account accepts when it signs up on the website:
// https://broka.co.ke/store/legal/terms and /privacy. "legal" is a reserved
// store link name (backend stores/naming.py). The text is the app's own
// copy (lib/legal-text.ts), so the web and the app accept the same words.
import type { Metadata } from 'next'
import { notFound } from 'next/navigation'

import { LegalText } from '@/components/LegalText'
import styles from '@/components/orders.module.css'
import { SiteFooter } from '@/components/SiteFooter'
import { SiteHeader } from '@/components/SiteHeader'
import { PRIVACY_MARKDOWN, TERMS_MARKDOWN } from '@/lib/legal'

const DOCS = {
  terms: { title: 'Terms of Use and Service', text: TERMS_MARKDOWN },
  privacy: { title: 'Privacy Policy', text: PRIVACY_MARKDOWN },
} as const

type Props = { params: Promise<{ doc: string }> }

export function generateStaticParams() {
  return Object.keys(DOCS).map((doc) => ({ doc }))
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { doc } = await params
  const found = DOCS[doc as keyof typeof DOCS]
  return { title: found ? `${found.title} · BROKA` : 'Not found' }
}

export default async function LegalPage({ params }: Props) {
  const { doc } = await params
  const found = DOCS[doc as keyof typeof DOCS]
  if (!found) notFound()
  return (
    <>
      <SiteHeader />
      <main className="page">
        <LegalText markdown={found.text} className={styles.legal} />
      </main>
      <SiteFooter />
    </>
  )
}
