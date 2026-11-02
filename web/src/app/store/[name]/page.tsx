// A store's home on the web: https://broka.co.ke/store/<name> - the shop's
// front window. Its cover photo and name, what buying here means, its
// departments, a few featured and new products, and the way into the full
// catalogue (/shop) and the business behind it (/about).
//
// Rendered on the server (link previews and search engines read it as is);
// store data is cached for a minute. Filtered views live on /shop, so a
// catalogue link shared into the homepage lands there instead.
import type { Metadata } from 'next'
import { notFound, permanentRedirect } from 'next/navigation'

import { CartDrawer } from '@/components/CartDrawer'
import { StoreLanding } from '@/components/StoreLanding'
import { StoreFooter } from '@/components/StoreFooter'
import { StoreHeader } from '@/components/StoreHeader'
import { StorefrontShell } from '@/components/StorefrontShell'
import { VisitBeacon } from '@/components/VisitBeacon'
import { getStore, getStoreCategories, getStoreListings } from '@/lib/api'
import { filtersQuery, readFilters, toProductCard } from '@/lib/catalogue'
import { campaignToken, storeCartPath, storeShopPath, viaTag } from '@/lib/links'
import { API_URL } from '@/lib/server-config'
import { jsonLdScript, storeDescription, storeJsonLd, storePreviewImage, storeView } from '@/lib/storefront'

type Props = {
  params: Promise<{ name: string }>
  searchParams: Promise<Record<string, string | string[] | undefined>>
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { name } = await params
  const store = await getStore(name)
  if (!store) return { title: 'Store not found', robots: { index: false } }
  const view = storeView(store)
  const description = storeDescription(store)
  const image = storePreviewImage(store)
  return {
    title: store.name,
    description,
    alternates: { canonical: view.path },
    openGraph: {
      type: 'website',
      url: view.url,
      title: `${store.name} on BROKA`,
      description,
      images: [image],
    },
    twitter: { card: 'summary_large_image', title: `${store.name} on BROKA`, description, images: [image.url] },
  }
}

export default async function StorePage({ params, searchParams }: Props) {
  const [{ name }, query] = await Promise.all([params, searchParams])
  const store = await getStore(name)
  if (!store) notFound()

  const via = viaTag(query.via)
  const campaign = campaignToken(query.c)
  const shopPath = storeShopPath(store.slug)
  if (name !== store.slug) {
    const q = new URLSearchParams()
    if (via) q.set('via', via)
    if (campaign) q.set('c', campaign)
    permanentRedirect(`/store/${store.slug}${q.size ? `?${q}` : ''}`)
  }

  const filters = readFilters(query)
  if (filters.q || filters.category || filters.subcategoryId || filters.sort !== 'featured' || filters.condition || filters.price) {
    const q = new URLSearchParams(filtersQuery(filters).slice(1))
    if (via) q.set('via', via)
    if (campaign) q.set('c', campaign)
    permanentRedirect(`${shopPath}${q.size ? `?${q}` : ''}`)
  }

  const view = storeView(store)
  const [categories, featured, newest] = store.is_active
    ? await Promise.all([
        getStoreCategories(store.id),
        getStoreListings(store.id, { limit: 8 }),
        getStoreListings(store.id, { sort: 'newest', limit: 8 }),
      ])
    : [[], [], []]
  const featuredCards = featured.map((listing) => toProductCard(listing, store.slug, API_URL))
  const featuredIds = new Set(featuredCards.map((product) => product.id))
  const newestCards = newest
    .map((listing) => toProductCard(listing, store.slug, API_URL))
    .filter((product) => !featuredIds.has(product.id))
  const landingProducts = [...featuredCards, ...newestCards].slice(0, 9)

  return (
    <StorefrontShell>
      <StoreHeader view={view} active="home" searchBase={shopPath} />
      <StoreLanding view={view} categories={categories} products={landingProducts} storeId={store.id} />
      <div className="page">
        <VisitBeacon storeId={store.id} via={via} campaign={campaign} />
        <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: jsonLdScript(storeJsonLd(view)) }} />
      </div>
      <StoreFooter view={view} categories={categories} />
      {store.is_active && <CartDrawer storeId={store.id} storeName={store.name} cartPath={storeCartPath(store.slug)} />}
    </StorefrontShell>
  )
}
