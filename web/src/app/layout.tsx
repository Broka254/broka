import type { Metadata, Viewport } from 'next'
import localFont from 'next/font/local'

import { BrandBackground } from '@/components/BrandBackground'
import { OpenInApp } from '@/components/OpenInApp'
import { SITE_URL } from '@/lib/config'
import { DEFAULT_PREVIEW_IMAGE, asset } from '@/lib/links'
import { PAY_RULE } from '@/lib/safety'

import './globals.css'

// The storefront's three typefaces, served from this site (./fonts, the
// latin subset of each, SIL Open Font License - the licence files sit
// beside them). Self-hosted on purpose: the build fetches nothing (CI and
// Vercel build without a network call for fonts), and a visitor's browser
// asks no third party for them. Inter for reading and the controls, Sora
// for the store's name, headings and prices, Space Mono for the small
// instrument labels (counts, tags, the section numbers) - one weight,
// 16 KB. The family names in the CSS come from these constants' names:
// distinct ones, so a page can never mean a system font called "sans".
const brokaInter = localFont({
  src: './fonts/inter-latin-wght.woff2',
  weight: '100 900',
  style: 'normal',
  display: 'swap',
  variable: '--font-inter',
})

const brokaSora = localFont({
  src: './fonts/sora-latin-wght.woff2',
  weight: '100 800',
  style: 'normal',
  display: 'swap',
  variable: '--font-sora',
})

const brokaMono = localFont({
  src: './fonts/space-mono-latin-400.woff2',
  weight: '400',
  style: 'normal',
  display: 'swap',
  variable: '--font-space-mono',
})

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: { default: 'BROKA', template: '%s · BROKA' },
  description: `Shop Kenyan stores on BROKA. ${PAY_RULE}.`,
  applicationName: 'BROKA',
  // In public/store-assets, not app/icon.png: /icon.png on broka.co.ke is
  // the BROKA website's (see ASSET_PREFIX).
  icons: {
    icon: { url: asset('/icon.png'), type: 'image/png', sizes: '192x192' },
    apple: { url: asset('/apple-icon.png'), type: 'image/png', sizes: '180x180' },
  },
  openGraph: {
    siteName: 'BROKA',
    type: 'website',
    images: [{ url: DEFAULT_PREVIEW_IMAGE, width: 1200, height: 630 }],
  },
  twitter: { card: 'summary_large_image' },
}

export const viewport: Viewport = {
  themeColor: '#04050b',
  colorScheme: 'dark',
  width: 'device-width',
  initialScale: 1,
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${brokaInter.variable} ${brokaSora.variable} ${brokaMono.variable}`}>
      <body>
        <BrandBackground />
        <OpenInApp />
        {children}
      </body>
    </html>
  )
}
