import type { MetadataRoute } from 'next'

import { SITE_URL } from '@/lib/config'

export default function robots(): MetadataRoute.Robots {
  return {
    // A buyer's orders are personal (and every page of them says noindex).
    rules: { userAgent: '*', allow: '/', disallow: ['/api/', '/store/orders'] },
    host: SITE_URL,
  }
}
