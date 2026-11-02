// A store's full catalogue: https://broka.co.ke/store/<name>/shop - every
// product with search, departments, sorting, condition and price filters.
// Search, category, sort, condition and price live in the URL, so every
// filtered view is a link that can be shared.
//
// Rendered on the server (link previews and search engines read it as is);
// store data is cached for a minute. The first page arrives with the HTML;
// further pages load through /api/stores/[id]/listings.
import type { Metadata } from 'next'
import Link from 'next/link'
import { notFound, permanentRedirect } from 'next/navigation'

import { CartDrawer } from '@/components/CartDrawer'
import { CategoryPills, hasStoreCategoryTiles } from '@/components/CategoryPills'
import { Icon } from '@/components/Icon'
import { ProductGrid } from '@/components/ProductGrid'
import { StoreFooter } from '@/components/StoreFooter'
import { StoreHeader } from '@/components/StoreHeader'
import { StorefrontShell } from '@/components/StorefrontShell'
import { VisitBeacon } from '@/components/VisitBeacon'
import shop from '@/components/shop.module.css'
import styles from '@/components/store.module.css'
import { getStore, getStoreCategories, getStoreListings } from '@/lib/api'
import { CONDITIONS, PRICE_BANDS, SORTS, filtersQuery, panelActive, readFilters, toProductCard } from '@/lib/catalogue'
import { PAGE_SIZE } from '@/lib/config'
import { absoluteUrl, campaignToken, storeCartPath, storeShopPath, viaTag } from '@/lib/links'
import { API_URL } from '@/lib/server-config'
import { storeDescription, storePreviewImage, storeView } from '@/lib/storefront'

type Props = {
  params: Promise<{ name: string }>
  searchParams: Promise<Record<string, string | string[] | undefined>>
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { name } = await params
  const store = await getStore(name)
  if (!store) return { title: 'Store not found', robots: { index: false } }
  const path = storeShopPath(store.slug)
  const description = storeDescription(store)
  const image = storePreviewImage(store)
  return {
    title: `Shop ${store.name}`,
    description,
    alternates: { canonical: path },
    openGraph: {
      type: 'website',
      url: absoluteUrl(path),
      title: `Shop ${store.name} on BROKA`,
      description,
      images: [image],
    },
    twitter: { card: 'summary_large_image', title: `Shop ${store.name} on BROKA`, description, images: [image.url] },
  }
}

export default async function StoreShopPage({ params, searchParams }: Props) {
  const [{ name }, query] = await Promise.all([params, searchParams])
  const store = await getStore(name)
  if (!store) notFound()

  const filters = readFilters(query)
  const via = viaTag(query.via)
  const campaign = campaignToken(query.c)
  const path = storeShopPath(store.slug)
  // One address per store: /store/Clanix/shop -> /store/clanix/shop.
  if (name !== store.slug) {
    const q = new URLSearchParams(filtersQuery(filters).slice(1))
    if (via) q.set('via', via)
    if (campaign) q.set('c', campaign)
    permanentRedirect(`${path}${q.size ? `?${q}` : ''}`)
  }

  const view = storeView(store)
  const [categories, listings] = store.is_active
    ? await Promise.all([
        getStoreCategories(store.id),
        getStoreListings(store.id, {
          q: filters.q,
          category: filters.category ?? undefined,
          subcategoryId: filters.subcategoryId ?? undefined,
          sort: filters.sort,
          condition: filters.condition,
          price: filters.price,
        }),
      ])
    : [[], []]
  const products = listings.map((l) => toProductCard(l, store.slug, API_URL))
  const selectedSubcategory = categories.flatMap((category) => category.subcategories ?? []).find((item) => item.id === filters.subcategoryId)
  const filtered = Boolean(filters.q || filters.category || filters.subcategoryId || panelActive(filters))
  // The chips over the grid: each filter in force, with a link that drops it.
  const applied = [
    filters.q && { label: `“${filters.q}”`, to: { q: '' } },
    filters.subcategoryId && { label: selectedSubcategory?.name ?? 'Category', to: { subcategoryId: null } },
    filters.sort !== 'featured' && { label: SORTS.find((x) => x.key === filters.sort)!.label, to: { sort: 'featured' as const } },
    filters.condition && { label: CONDITIONS.find((c) => c.key === filters.condition)!.label, to: { condition: null } },
    filters.price && { label: `KES ${PRICE_BANDS.find((b) => b.key === filters.price)!.label}`, to: { price: null } },
  ].filter(Boolean) as Array<{ label: string; to: Partial<typeof filters> }>
  const count =
    filtered || !store.is_active
      ? null
      : filters.category
        ? categories.find((c) => c.name === filters.category)?.count
        : store.listing_count

  return (
    <StorefrontShell>
      <StoreHeader view={view} active="shop" filters={filters} searchBase={path} showSectionNav={false} />
      <main className={`page ${shop.storePage}`}>
        <nav aria-label="Breadcrumb" className={shop.crumbs}>
          <Link href={view.path}>{store.name}</Link>
          <Icon name="chevron" size={14} />
          <span aria-current="page">Shop</span>
        </nav>
        <h1 className={styles.detailsTitle}>Shop {store.name}</h1>
        {store.is_active && (
          <section aria-labelledby="catalogue-title" className={shop.catalogue}>
            {hasStoreCategoryTiles(categories) && (
              <div className={shop.homeSection}>
                <div className={shop.sectionHead}>
                  <h2>Shop by category</h2>
                  <Link href={path} className={shop.seeAll}>All products <Icon name="chevron" size={14} /></Link>
                </div>
                <CategoryPills basePath={path} categories={categories} filters={filters} />
              </div>
            )}
            <div className={shop.toolbar}>
              <h2 id="catalogue-title">
                {selectedSubcategory?.name ?? filters.category ?? 'All products'}
                {count != null && <span className={shop.countTag}>{count}</span>}
              </h2>
              {applied.length > 0 && (
                <ul className={shop.applied} aria-label="Filters in use">
                  {applied.map((a) => (
                    <li key={a.label}>
                      <a href={`${path}${filtersQuery({ ...filters, ...a.to })}`} aria-label={`Remove ${a.label}`}>
                        {a.label} <Icon name="close" size={13} />
                      </a>
                    </li>
                  ))}
                </ul>
              )}
            </div>
            {filtered && (
              <p className={styles.resultNote} role="status">
                {products.length === 0 ? 'No products' : products.length >= PAGE_SIZE ? 'Products' : `${products.length} product${products.length === 1 ? '' : 's'}`}
                {filters.q ? ` matching “${filters.q}”` : ''}
                {filters.category ? ` in ${filters.category}` : selectedSubcategory ? ` in ${selectedSubcategory.name}` : ''} · <a href={path}>Show everything</a>
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
                <span className={shop.emptyCartIcon}>
                  <Icon name={filtered ? 'search' : 'bag'} size={34} />
                </span>
                <h2>{filtered ? 'No products match' : 'Nothing listed yet'}</h2>
                <p>{filtered ? 'Try another search or filter.' : 'Check back soon: this store is just getting started.'}</p>
              </div>
            )}
          </section>
        )}
        <VisitBeacon storeId={store.id} via={via} campaign={campaign} />
      </main>
      <StoreFooter view={view} categories={categories} />
      {store.is_active && <CartDrawer storeId={store.id} storeName={store.name} cartPath={storeCartPath(store.slug)} />}
    </StorefrontShell>
  )
}
