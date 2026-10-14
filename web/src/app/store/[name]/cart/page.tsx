// A store's cart and checkout on the web: https://broka.co.ke/store/<name>/cart.
// The cart itself is in the visitor's browser (CheckoutView reads it); the
// page is the frame around it. Not indexed: it's different for everyone.
import type { Metadata } from 'next'
import { notFound, permanentRedirect, redirect } from 'next/navigation'

import { CheckoutView } from '@/components/CheckoutView'
import { StoreFooter } from '@/components/StoreFooter'
import { StoreHeader } from '@/components/StoreHeader'
import shop from '@/components/shop.module.css'
import { getStore } from '@/lib/api'
import { storeCartPath } from '@/lib/links'
import { storeView } from '@/lib/storefront'

type Props = { params: Promise<{ name: string }> }

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { name } = await params
  const store = await getStore(name)
  return { title: store ? `Your cart · ${store.name}` : 'Store not found', robots: { index: false } }
}

export default async function CartPage({ params }: Props) {
  const { name } = await params
  const store = await getStore(name)
  if (!store) notFound()
  if (name !== store.slug) permanentRedirect(storeCartPath(store.slug))
  const view = storeView(store)
  // A paused store sells nothing; its page says so.
  if (!store.is_active) redirect(view.path)
  return (
    <>
      <StoreHeader view={view} />
      <main className={`page ${shop.storePage}`}>
        <CheckoutView
          storeId={store.id}
          storeName={store.name}
          storePath={view.path}
          cartPath={storeCartPath(store.slug)}
          storeUrl={view.url}
        />
      </main>
      <StoreFooter view={view} />
    </>
  )
}
