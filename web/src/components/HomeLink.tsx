import type { AnchorHTMLAttributes } from 'react'

/**
 * A link to BROKA's home page. "/" on broka.co.ke is the BROKA website, a
 * different deployment that passes the storefront's paths on to this one,
 * so this is a plain <a>: a Next <Link> would try to load the website's home
 * page into the storefront instead of going there (Next.js "multi-zones").
 */
export function HomeLink(props: Omit<AnchorHTMLAttributes<HTMLAnchorElement>, 'href'>) {
  // eslint-disable-next-line @next/next/no-html-link-for-pages -- "/" isn't one of this site's pages
  return <a {...props} href="/" />
}
