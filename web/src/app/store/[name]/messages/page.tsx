// Messaging a store from its website: https://broka.co.ke/store/<name>/messages,
// or ?product=<id> to ask about one of its products. The conversation is
// the buyer's own and is read in the browser (EnquiryThread); the page is
// the frame. Not indexed: it is different for everyone.
import type { Metadata } from 'next'
import { notFound, permanentRedirect, redirect } from 'next/navigation'

import { EnquiryThread } from '@/components/EnquiryThread'
import { StoreFooter } from '@/components/StoreFooter'
import { StoreHeader } from '@/components/StoreHeader'
import { StorefrontShell } from '@/components/StorefrontShell'
import shop from '@/components/shop.module.css'
import { getListing, getStore } from '@/lib/api'
import { storeMessagesPath, storePath } from '@/lib/links'
import { storeView } from '@/lib/storefront'

type Props = {
  params: Promise<{ name: string }>
  searchParams: Promise<Record<string, string | string[] | undefined>>
}

const ID = /^[A-Za-z0-9-]{1,64}$/

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { name } = await params
  const store = await getStore(name)
  return { title: store ? `Message ${store.name}` : 'Store not found', robots: { index: false } }
}

export default async function StoreMessagesPage({ params, searchParams }: Props) {
  const [{ name }, query] = await Promise.all([params, searchParams])
  const store = await getStore(name)
  if (!store) notFound()
  const raw = Array.isArray(query.product) ? query.product[0] : query.product
  const productId = raw && ID.test(raw) ? raw : undefined
  if (name !== store.slug) permanentRedirect(storeMessagesPath(store.slug, productId))
  // Messaging on the website comes with store orders: while they are off,
  // the store's page offers the app, as before.
  if (!store.is_active || store.orders_enabled !== true) redirect(storePath(store.slug))
  // A product from another store is not this store's to answer about.
  const listing = productId ? await getListing(productId).catch(() => null) : null
  const product = listing && listing.store_id === store.id ? listing : null
  const view = storeView(store)
  return (
    <StorefrontShell>
      <StoreHeader view={view} active="about" />
      <main className={`page ${shop.storePage}`}>
        <EnquiryThread
          storeId={store.id}
          storeName={store.name}
          listingId={product?.id}
          productName={product?.name}
        />
      </main>
      <StoreFooter view={view} />
    </StorefrontShell>
  )
}
