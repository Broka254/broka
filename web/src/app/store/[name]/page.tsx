// A store's home on the web: https://broka.co.ke/store/<name> - the shop's
// front window. Its cover photo and name, what buying here means, its
// departments, a few featured and new products, and the way into the full
// catalogue (/shop) and the business behind it (/about).
//
// Rendered on the server (link previews and search engines read it as is);
// store data is cached for a minute. Filtered views live on /shop, so a
// catalogue link shared into the homepage lands there instead.
import type { Metadata } from 'next'
import Link from 'next/link'
import { notFound, permanentRedirect } from 'next/navigation'

import { CartDrawer } from '@/components/CartDrawer'
import { CategoryPills } from '@/components/CategoryPills'
import { Icon } from '@/components/Icon'
import { Perks } from '@/components/Perks'
import { ProductCard } from '@/components/ProductCard'
import { StoreFooter } from '@/components/StoreFooter'
import { StoreHeader } from '@/components/StoreHeader'
import { StoreHero } from '@/components/StoreHero'
import { VisitBeacon } from '@/components/VisitBeacon'
import shop from '@/components/shop.module.css'
import styles from '@/components/store.module.css'
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
  // One address per store: /store/Clanix -> /store/clanix.
  if (name !== store.slug) {
    const q = new URLSearchParams()
    if (via) q.set('via', via)
    if (campaign) q.set('c', campaign)
    permanentRedirect(`/store/${store.slug}${q.size ? `?${q}` : ''}`)
  }
  // Filtered catalogue views live on /shop now: an old shared link with
  // search or filters lands there with them intact.
  const filters = readFilters(query)
  if (filters.q || filters.category || filters.sort !== 'featured' || filters.condition || filters.price) {
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
  const featuredCards = featured.map((l) => toProductCard(l, store.slug, API_URL))
  const featuredIds = new Set(featuredCards.map((p) => p.id))
  // Newest earns its own shelf only when it isn't the same products again.
  const newestCards = newest
    .map((l) => toProductCard(l, store.slug, API_URL))
    .filter((p) => !featuredIds.has(p.id))
    .slice(0, 8)
  const hasCatalogue = featuredCards.length > 0 || categories.length > 1

  return (
    <>
      <StoreHeader view={view} active="home" searchBase={shopPath} />
      <main className={`page ${shop.storePage}`}>
        <StoreHero view={view} showcase={featuredCards} />
        {store.is_active && (
          <>
            <Perks verified={Boolean(store.owner?.verified)} />
            {categories.length > 1 && (
              <section aria-labelledby="departments-title" className={shop.homeSection}>
                <div className={shop.sectionHead}>
                  <h2 id="departments-title">Shop by category</h2>
                  <Link href={shopPath} className={shop.seeAll}>
                    All products <Icon name="chevron" size={14} />
                  </Link>
                </div>
                <CategoryPills basePath={shopPath} categories={categories} total={store.listing_count} filters={filters} />
              </section>
            )}
            {featuredCards.length > 0 && (
              <section aria-labelledby="featured-title" className={shop.homeSection}>
                <div className={shop.sectionHead}>
                  <h2 id="featured-title">Featured products</h2>
                  {store.listing_count > featuredCards.length && (
                    <Link href={shopPath} className={shop.seeAll}>
                      See all <Icon name="chevron" size={14} />
                    </Link>
                  )}
                </div>
                <div className={shop.grid}>
                  {featuredCards.map((p) => (
                    <ProductCard key={p.id} product={p} storeId={store.id} />
                  ))}
                </div>
              </section>
            )}
            {newestCards.length > 0 && (
              <section aria-labelledby="newest-title" className={shop.homeSection}>
                <div className={shop.sectionHead}>
                  <h2 id="newest-title">Newly added</h2>
                  <Link href={`${shopPath}${filtersQuery({ sort: 'newest' })}`} className={shop.seeAll}>
                    See all <Icon name="chevron" size={14} />
                  </Link>
                </div>
                <div className={shop.grid}>
                  {newestCards.map((p) => (
                    <ProductCard key={p.id} product={p} storeId={store.id} />
                  ))}
                </div>
              </section>
            )}
            {!hasCatalogue && (
              <div className={`card ${styles.empty}`}>
                <span className={shop.emptyCartIcon}>
                  <Icon name="bag" size={34} />
                </span>
                <h2>Nothing listed yet</h2>
                <p>Check back soon: this store is just getting started.</p>
              </div>
            )}
            {view.description && (
              <section aria-labelledby="intro-title" className={shop.aboutTeaser}>
                <div className={`card ${styles.detailsCard} ${shop.aboutTeaserCard}`}>
                  <h2 id="intro-title">About {store.name}</h2>
                  <p>{view.description}</p>
                  <Link href={`${view.path}/about`} className={shop.seeAll}>
                    More about this business <Icon name="chevron" size={14} />
                  </Link>
                </div>
              </section>
            )}
          </>
        )}
        <VisitBeacon storeId={store.id} via={via} campaign={campaign} />
        <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: jsonLdScript(storeJsonLd(view)) }} />
      </main>
      <StoreFooter view={view} categories={categories} />
      {store.is_active && <CartDrawer storeId={store.id} storeName={store.name} cartPath={storeCartPath(store.slug)} />}
    </>
  )
}
