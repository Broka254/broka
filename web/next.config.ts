import type { NextConfig } from 'next'

// Security headers for every page. The storefront loads its images from the
// BROKA API and the R2 media domain, so no CSP img-src allow-list is set
// here (it would have to track MEDIA_PUBLIC_BASE_URL); framing is refused.
const securityHeaders = [
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'X-Frame-Options', value: 'DENY' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=()' },
]

const nextConfig: NextConfig = {
  poweredByHeader: false,
  reactStrictMode: true,
  async headers() {
    return [{ source: '/:path*', headers: securityHeaders }]
  },
}

export default nextConfig
