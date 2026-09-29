// A store's details on the web: https://broka.co.ke/store/<name>/about.
//
// Linked from "More details" under the store's name, so the store's home is
// left to its products. The app opens the same link on its own Store
// details screen.
import type { Metadata } from 'next'
import Link from 'next/link'
import { notFound, permanentRedirect } from 'next/navigation'

import { SiteFooter } from '@/components/SiteFooter'
import { SiteHeader } from '@/components/SiteHeader'
import { StoreDetails } from '@/components/StoreDetails'
import { VisitBeacon } from '@/components/VisitBeacon'
import styles from '@/components/store.module.css'
import { getStore } from '@/lib/api'
import { absoluteUrl, storeDetailsPath, viaTag } from '@/lib/links'
import { storeDescription, storePreviewImage, storeView } from '@/lib/storefront'

type Props = {
  params: Promise<{ name: string }>
  searchParams: Promise<Record<string, string | string[] | undefined>>
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { name } = await params
  const store = await getStore(name)
  if (!store) return { title: 'Store not found', robots: { index: false } }
  const path = storeDetailsPath(store.slug)
  const description = storeDescription(store)
  const image = storePreviewImage(store)
  return {
    title: `${store.name} · Store details`,
    description,
    alternates: { canonical: path },
    openGraph: {
      type: 'website',
      url: absoluteUrl(path),
      title: `${store.name} on BROKA`,
      description,
      images: [image],
    },
  }
}

export default async function StoreDetailsPage({ params, searchParams }: Props) {
  const [{ name }, query] = await Promise.all([params, searchParams])
  const store = await getStore(name)
  if (!store) notFound()
  const via = viaTag(query.via)
  // One address per store: /store/Clanix/about -> /store/clanix/about.
  if (name !== store.slug) permanentRedirect(`${storeDetailsPath(store.slug)}${via ? `?via=${via}` : ''}`)

  const view = storeView(store)
  return (
    <>
      <SiteHeader />
      <main className="page">
        <Link href={view.path} className={styles.back}>
          <span className={styles.backLogo}>
            {view.logo ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={view.logo} alt="" />
            ) : (
              <span aria-hidden="true">{view.initial}</span>
            )}
          </span>
          ← Back to {store.name}
        </Link>
        <h1 className={styles.detailsTitle}>Store details</h1>
        <StoreDetails view={view} />
        <VisitBeacon storeId={store.id} via={via} />
      </main>
      <SiteFooter />
    </>
  )
}
