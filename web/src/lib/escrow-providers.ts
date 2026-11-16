// The escrow providers BROKA lists, as the API serves them
// (GET /escrow-providers, backend/api/domains/escrow_directory).
//
// ONE LIST, THE API'S. This site used to carry its own copy of the providers
// (lib/safety.ts) and a test that read the backend's Python source to check
// the two matched. A copy cannot be corrected without a deploy, cannot say a
// provider was suspended, and was the only place that still listed
// escrowkenya.com as active. The page now asks the API, and when it cannot
// answer it says so: a stale list shown as the current one is worse than
// none - this is the screen that tells people which website to send money to.
//
// This file has no server-only imports, so it can be tested directly; the
// fetch itself is in api.ts.

/** What the page needs of a listed provider. The API sends much more. */
export interface EscrowProvider {
  id: string
  name: string
  /** The provider's official https address, already checked by safeProviders. */
  url: string
  /** Shown beside the name: what is and is not yet known about it. */
  reviewLabel: string
  /** "Fee not publicly specified – confirm before paying", and so on. */
  feeSummary: string
  /** One line: limits, and whether an account is needed. */
  summary: string
  /** Set when BROKA has not finished reviewing it, or its pricing is out of date. */
  warning: string | null
  /** "Not the same company as Escrow Kenya (escrowkenya.com)". */
  notToBeConfusedWith: string | null
}

/** The API's answer, as far as this site reads it. */
export interface DirectoryResponse {
  providers: unknown[]
  disclosures?: { main?: string; points?: string[] }
  notices?: { name?: string; domain?: string; public_notice?: string | null }[]
}

export interface EscrowDirectory {
  providers: EscrowProvider[]
  /** The notice BROKA must show wherever it shows a provider. */
  disclaimer: string
  notices: string[]
}

/**
 * The words BROKA must show with any provider. Used when the API cannot be
 * reached, so even then the page says who is responsible for the money. Kept
 * identical to backend escrow_directory/disclosures.py (a test pins the text).
 */
export const REQUIRED_NOTICE =
  "Broka does not operate these escrow services and does not hold, receive or release your money. The services are provided independently by their respective operators. Broka does not guarantee their performance or independently control their funds. Review the provider's current fees, conditions, refund policy and dispute procedures before paying."

/**
 * Whether [url] is an https address on exactly [domain] (or www.[domain]).
 * The same rule as the backend's links.official_url: exact host match, never
 * "ends with"; no user-info; no odd port; no punycode. A response that fails
 * it is dropped, not shown with a warning: a wrong link is the harm.
 */
export function isOfficialUrl(url: unknown, domain: unknown): url is string {
  if (typeof url !== 'string' || typeof domain !== 'string' || url.length > 300) return false
  if (!/^(?=.{4,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,23}$/.test(domain)) return false
  if (domain.startsWith('www.') || domain.split('.').some((label) => label.startsWith('xn--'))) return false
  if (/[\s\\<>"'`\u0000-\u001f\u007f]/.test(url)) return false
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return false
  }
  if (parsed.protocol !== 'https:') return false
  if (parsed.username !== '' || parsed.password !== '') return false
  if (parsed.port !== '') return false // URL drops the default 443, so any port left is not it
  return parsed.hostname === domain || parsed.hostname === `www.${domain}`
}

function text(value: unknown, limit = 400): string {
  return typeof value === 'string' ? value.replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, limit) : ''
}

/**
 * The providers in [response] that are safe to show, in the shape the page
 * needs. A provider whose id, name, domain or address is missing or not
 * official is left out; nothing is repaired or guessed.
 */
export function safeProviders(response: DirectoryResponse | null | undefined): EscrowProvider[] {
  const out: EscrowProvider[] = []
  for (const raw of Array.isArray(response?.providers) ? response!.providers : []) {
    const p = raw as Record<string, any> // eslint-disable-line @typescript-eslint/no-explicit-any
    const domain = p?.canonical_domain
    if (typeof p?.id !== 'string' || !text(p?.name) || !isOfficialUrl(p?.website_url, domain)) continue
    // Only listed providers are ever sent here, but a suspended one that slipped
    // through (an old cache, a bug) must not be shown as a recommendation.
    if (p.status !== 'approved' && p.status !== 'under_review') continue
    const warnings: string[] = Array.isArray(p?.freshness?.warnings) ? p.freshness.warnings : []
    const confusable = Array.isArray(p?.not_to_be_confused_with) ? p.not_to_be_confused_with[0] : null
    out.push({
      id: p.id,
      name: text(p.name, 60),
      url: p.website_url,
      reviewLabel: text(p.review_label, 80),
      feeSummary: text(p?.summaries?.fees ?? p?.fee_summary, 240),
      summary: [text(p?.summaries?.limits, 120), text(p?.summaries?.requirements, 120)].filter(Boolean).join(' · '),
      warning: p.status === 'approved' && warnings.length === 0 ? null : text(warnings[0] ?? p.review_label, 300) || null,
      notToBeConfusedWith:
        confusable && text(confusable.name) && typeof confusable.domain === 'string'
          ? `Not the same company as ${text(confusable.name, 60)} (${text(confusable.domain, 60)}).`
          : null,
    })
  }
  return out
}

/** [response] as the page shows it; the required notice is always present. */
export function directoryView(response: DirectoryResponse | null | undefined): EscrowDirectory {
  const notices = (Array.isArray(response?.notices) ? response!.notices! : [])
    .map((n) => text(n?.public_notice, 400))
    .filter(Boolean)
  const main = text(response?.disclosures?.main, 1000)
  return { providers: safeProviders(response), disclaimer: main || REQUIRED_NOTICE, notices }
}

/** What the page shows when the API cannot be reached. No providers: none is a stale one. */
export const UNAVAILABLE: EscrowDirectory = { providers: [], disclaimer: REQUIRED_NOTICE, notices: [] }
