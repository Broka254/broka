// Android App Links: lets broka.co.ke/store links open straight in the app
// once ANDROID_CERT_SHA256 lists the app's signing certificate
// fingerprint(s). Empty until then, which Android reads as "not verified".
import { ANDROID_PACKAGE } from '@/lib/config'

export const dynamic = 'force-dynamic'

export function GET() {
  const fingerprints = (process.env.ANDROID_CERT_SHA256 ?? '')
    .split(',')
    .map((f) => f.trim().toUpperCase())
    .filter((f) => /^([0-9A-F]{2}:){31}[0-9A-F]{2}$/.test(f))
  const body = fingerprints.length
    ? [
        {
          relation: ['delegate_permission/common.handle_all_urls'],
          target: { namespace: 'android_app', package_name: ANDROID_PACKAGE, sha256_cert_fingerprints: fingerprints },
        },
      ]
    : []
  return Response.json(body, { headers: { 'Cache-Control': 'public, max-age=3600' } })
}
