// Who is signed in on this browser (GET), and signing out (DELETE).
import { type NextRequest, NextResponse } from 'next/server'

import { REFRESH_COOKIE, callApi, crossSite, signedOut, withCookies } from '@/lib/session'

export const dynamic = 'force-dynamic'

/** The page shows the buyer their own number back (to fill the contact
 *  field); anything else about the account stays with the API. */
function sessionUser(data: unknown) {
  const u = (data ?? {}) as Record<string, unknown>
  return {
    id: typeof u.id === 'string' ? u.id : null,
    name: typeof u.name === 'string' ? u.name : null,
    phone: typeof u.phone === 'string' ? u.phone : null,
  }
}

export async function GET(req: NextRequest) {
  const hasSession = req.cookies.get('broka_at') || req.cookies.get(REFRESH_COOKIE)
  if (!hasSession) return withCookies(NextResponse.json({ signed_in: false }), [])
  const result = await callApi(req, '/auth/me')
  if (result.status === 200) {
    return withCookies(NextResponse.json({ signed_in: true, user: sessionUser(result.data) }), result.cookies)
  }
  if (result.status === 401) return withCookies(NextResponse.json({ signed_in: false }), result.cookies)
  return withCookies(
    NextResponse.json({ signed_in: false, error: { code: 'API_UNREACHABLE', message: "Couldn't reach BROKA." } },
      { status: 503 }),
    result.cookies,
  )
}

export async function DELETE(req: NextRequest) {
  const refused = crossSite(req)
  if (refused) return refused
  const refreshToken = req.cookies.get(REFRESH_COOKIE)?.value
  if (refreshToken) {
    // Ends the session on the API too, so a copied cookie stops working.
    await callApi(req, '/auth/token/revoke', { method: 'POST', body: { refresh_token: refreshToken }, auth: false })
  }
  return withCookies(NextResponse.json({ signed_in: false }), signedOut)
}
