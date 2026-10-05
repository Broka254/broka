import type { Metadata, Viewport } from 'next'

import { Constellation } from '@/components/Constellation'
import { OpenInApp } from '@/components/OpenInApp'
import { SITE_URL } from '@/lib/config'
import { DEFAULT_PREVIEW_IMAGE, asset } from '@/lib/links'
import { PAY_RULE } from '@/lib/safety'

import './globals.css'

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
  themeColor: '#03040a',
  colorScheme: 'dark',
  width: 'device-width',
  initialScale: 1,
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Constellation />
        <OpenInApp />
        {children}
      </body>
    </html>
  )
}
