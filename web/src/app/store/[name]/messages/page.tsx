// Messaging a store from its website: https://broka.co.ke/store/<name>/messages,
// or ?product=<id> to ask about one of its products. The conversation is
// the buyer's own and is read in the browser (MessagingWorkspace); the page
// is the frame - the store's header with Messages marked, and the store and
// product the conversation is about, so the buyer is never more than a tap
// from the product, the shop or the cart. Not indexed: it is different for
// everyone.
import type { Metadata, Viewport } from 'next'
import Link from 'next/link'
import { notFound, permanentRedirect, redirect } from 'next/navigation'

import { CartDrawer } from '@/components/CartDrawer'
import { Icon } from '@/components/Icon'
import { MessagingWorkspace } from '@/components/MessagingWorkspace'
import { StoreFooter } from '@/components/StoreFooter'
import { StoreHeader } from '@/components/StoreHeader'
import { StorefrontShell } from '@/components/StorefrontShell'
import shop from '@/components/shop.module.css'
import { getListing, getStore } from '@/lib/api'
import { toProductCard } from '@/lib/catalogue'
import { resolveSizes } from '@/lib/images'
import { storeCartPath, storeMessagesPath, storePath, storeShopPath } from '@/lib/links'
import { API_URL } from '@/lib/server-config'
import { storeView } from '@/lib/storefront'

type Props = {
  params: Promise<{ name: string }>
  searchParams: Promise<Record<string, string | string[] | undefined>>
}

const ID = /^[A-Za-z0-9-]{1,64}$/

// A chat screen on a phone: where the browser supports it (Chrome on
// Android), the keyboard shrinks the page instead of covering it, so the
// box being typed into stays above the keyboard with the newest messages.
export const viewport: Viewport = {
  themeColor: '#04050b',
  colorScheme: 'dark',
  width: 'device-width',
  initialScale: 1,
  interactiveWidget: 'resizes-content',
}

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
  const card = product ? toProductCard(product, store.slug, API_URL) : null
  // The small size for the conversation's header, never a legacy base64
  // photo (the product page shows those).
  const thumb = product ? resolveSizes(product.cover ?? product.photos?.[0] ?? null, API_URL)?.thumb ?? null : null

  return (
    <StorefrontShell layout="chat">
      <StoreHeader view={view} active="messages" />
      <main id="main-content" className={`page ${shop.storePage}`}>
        <nav aria-label="Breadcrumb" className={shop.crumbs}>
          <Link href={view.path}>{store.name}</Link>
          <Icon name="chevron" size={14} />
          {product && card ? (
            <>
              <Link href={card.href}>{product.name}</Link>
              <Icon name="chevron" size={14} />
            </>
          ) : null}
          <span aria-current="page">Messages</span>
        </nav>
        <MessagingWorkspace
          store={{
            id: store.id,
            slug: store.slug,
            name: store.name,
            logo: view.logo && !view.logo.startsWith('data:') ? view.logo : null,
            href: view.path,
            shopHref: storeShopPath(store.slug),
          }}
          product={
            product && card
              ? {
                  id: product.id,
                  name: product.name,
                  image: thumb,
                  emoji: card.emoji,
                  priceLabel: typeof product.price === 'number' ? card.priceLabel : null,
                  href: card.href,
                }
              : null
          }
          back={
            product && card
              ? { href: card.href, label: `Back to ${product.name}` }
              : { href: view.path, label: `Back to ${store.name}` }
          }
        />
      </main>
      <StoreFooter view={view} />
      <CartDrawer storeId={store.id} storeName={store.name} cartPath={storeCartPath(store.slug)} />
    </StorefrontShell>
  )
}
