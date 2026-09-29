// A store's home on the web: https://broka.co.ke/store/<name>.
//
// Rendered on the server (link previews and search engines read it as
// is); store data is cached for a minute. Search, category and sort live
// in the URL, so every filtered view is a link that can be shared.
import type { Metadata } from 'next'
import { notFound, permanentRedirect } from 'next/navigation'

import { CatalogueControls } from '@/components/CatalogueControls'
import { CategoryPills } from '@/components/CategoryPills'
import { ProductGrid } from '@/components/ProductGrid'
import { SiteFooter } from '@/components/SiteFooter'
import { SiteHeader } from '@/components/SiteHeader'
import { StoreHero } from '@/components/StoreHero'
import { VisitBeacon } from '@/components/VisitBeacon'
import styles from '@/components/store.module.css'
import { getStore, getStoreCategories, getStoreListings } from '@/lib/api'
import { filtersQuery, readFilters, toProductCard } from '@/lib/catalogue'
import { PAGE_SIZE } from '@/lib/config'
import { viaTag } from '@/lib/links'
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

  const filters = readFilters(query)
  const via = viaTag(query.via)
  // One address per store: /store/Clanix -> /store/clanix.
  if (name !== store.slug) {
    const q = new URLSearchParams(filtersQuery(filters).slice(1))
    if (via) q.set('via', via)
    permanentRedirect(`/store/${store.slug}${q.size ? `?${q}` : ''}`)
  }

  const view = storeView(store)
  const [categories, listings] = store.is_active
    ? await Promise.all([
        getStoreCategories(store.id),
        getStoreListings(store.id, { q: filters.q, category: filters.category ?? undefined, sort: filters.sort }),
      ])
    : [[], []]
  const products = listings.map((l) => toProductCard(l, store.slug, API_URL))
  const filtered = Boolean(filters.q || filters.category)

  return (
    <>
      <SiteHeader />
      <main className="page">
        <StoreHero view={view} />
        {store.is_active && (
          <section aria-label="Products">
            {categories.length > 0 && (
              <CategoryPills basePath={view.path} categories={categories} total={store.listing_count} filters={filters} />
            )}
            <CatalogueControls basePath={view.path} filters={filters} />
            {filtered && (
              <p className={styles.resultNote} role="status">
                {products.length === 0 ? 'No products' : products.length >= PAGE_SIZE ? 'Products' : `${products.length} product${products.length === 1 ? '' : 's'}`}
                {filters.q ? ` matching “${filters.q}”` : ''}
                {filters.category ? ` in ${filters.category}` : ''} ·{' '}
                <a href={view.path}>Show everything</a>
              </p>
            )}
            {products.length > 0 ? (
              <ProductGrid
                key={filtersQuery(filters)}
                storeId={store.id}
                slug={store.slug}
                filters={filters}
                initial={products}
                pageSize={PAGE_SIZE}
              />
            ) : (
              <div className={`card ${styles.empty}`}>
                <p aria-hidden="true" style={{ fontSize: 34, margin: 0 }}>
                  {filtered ? '🔍' : '📦'}
                </p>
                <h2>{filtered ? 'No products match' : 'Nothing listed yet'}</h2>
                <p>{filtered ? 'Try another search or category.' : 'Check back soon: this store is just getting started.'}</p>
              </div>
            )}
          </section>
        )}
        <VisitBeacon storeId={store.id} via={via} />
        <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: jsonLdScript(storeJsonLd(view)) }} />
      </main>
      <SiteFooter />
    </>
  )
}
