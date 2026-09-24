import type { Metadata, Viewport } from 'next'

import { Constellation } from '@/components/Constellation'
import { OpenInApp } from '@/components/OpenInApp'
import { SITE_URL } from '@/lib/config'
import { DEFAULT_PREVIEW_IMAGE } from '@/lib/links'

import './globals.css'

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: { default: 'BROKA', template: '%s · BROKA' },
  description: "Shop Kenyan stores on BROKA: every purchase protected until you've received it.",
  applicationName: 'BROKA',
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
