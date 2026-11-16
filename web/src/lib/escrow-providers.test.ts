// lib/escrow-providers.ts: what the website will and will not show as an
// escrow provider. The rules are the same as the backend's
// (escrow_directory/links.py): a link is shown only when it is an https
// address on exactly the provider's own domain, because this is the list that
// tells people where to send money and a wrong link is the harm.
import { describe, expect, it } from 'vitest'

import { directoryView, isOfficialUrl, REQUIRED_NOTICE, safeProviders, UNAVAILABLE } from './escrow-providers'

/** The one provider a call returned; fails the test if there is none. */
function only<T>(items: T[]): T {
  expect(items).toHaveLength(1)
  return items[0] as T
}

const provider = (over: Record<string, unknown> = {}) => ({
  id: 'kenyaescrow',
  name: 'Kenya Escrow',
  status: 'under_review',
  review_label: 'Under review: not yet verified by Broka',
  website_url: 'https://kenyaescrow.com/',
  canonical_domain: 'kenyaescrow.com',
  summaries: { fees: 'Fee depends on the amount', limits: 'KSh 50 to KSh 240,000', requirements: 'No account required.' },
  freshness: { warnings: [] },
  ...over,
})

describe('isOfficialUrl', () => {
  it.each([
    'https://kenyaescrow.com',
    'https://kenyaescrow.com/pricing?x=1',
    'https://www.kenyaescrow.com/faq',
    'https://KenyaEscrow.com:443/faq',
  ])('accepts the provider\u2019s own page: %s', (url: string) => {
    expect(isOfficialUrl(url, 'kenyaescrow.com')).toBe(true)
  })

  it.each([
    'https://kenyaescrow.com@evil.example/', // the browser goes to evil.example
    'https://user@kenyaescrow.com/', // right host, but never legitimate in a link we hand out
    'https://kenyaescrow.com.evil.example/', // ends in a name it does not own
    'https://evilkenyaescrow.com/', // contains the name
    'http://kenyaescrow.com/', // not https
    'https://kenyaescrow.com:8443/x', // odd port
    'https://xn--kenyaescrw-8cf.com/', // punycode look-alike
    'https://sub.kenyaescrow.com/', // only the apex and www
    'https://escrowkenya.com/', // the other company
    'javascript:alert(1)',
    'data:text/html,x',
    '//kenyaescrow.com/',
    'kenyaescrow.com',
    'https://kenyaescrow.com/\n',
    'https://kenya escrow.com/',
    '',
  ])('refuses a look-alike or unsafe address: %j', (url: string) => {
    expect(isOfficialUrl(url, 'kenyaescrow.com')).toBe(false)
  })

  it('refuses non-text input and a domain that is not plain', () => {
    for (const bad of [null, undefined, 5, {}, []]) expect(isOfficialUrl(bad, 'kenyaescrow.com')).toBe(false)
    for (const domain of ['www.kenyaescrow.com', 'KenyaEscrow.com', 'xn--abc.com', 'kenyaescrow', '', null, 5]) {
      expect(isOfficialUrl('https://kenyaescrow.com/', domain)).toBe(false)
    }
  })

  it('refuses an address that is far too long', () => {
    expect(isOfficialUrl(`https://kenyaescrow.com/${'a'.repeat(400)}`, 'kenyaescrow.com')).toBe(false)
  })
})

describe('safeProviders', () => {
  it('keeps a good provider, with its words ready to show', () => {
    const p = only(safeProviders({ providers: [provider()] }))
    expect(p).toMatchObject({ id: 'kenyaescrow', name: 'Kenya Escrow', url: 'https://kenyaescrow.com/' })
    expect(p.feeSummary).toBe('Fee depends on the amount')
    expect(p.summary).toBe('KSh 50 to KSh 240,000 \u00b7 No account required.')
    expect(p.warning).toBe('Under review: not yet verified by Broka')
  })

  it('drops a provider whose address is not on its own domain - it is not shown with a warning', () => {
    const bad = provider({ website_url: 'https://kenya-escrow-pay.com/' })
    expect(safeProviders({ providers: [bad] })).toEqual([])
  })

  it('drops a provider that is not listed (a stale cache, a bug)', () => {
    for (const status of ['suspended', 'rejected', 'draft', undefined]) {
      expect(safeProviders({ providers: [provider({ status })] })).toEqual([])
    }
  })

  it('drops anything malformed rather than guessing', () => {
    const response = { providers: [null, 5, 'x', {}, provider({ id: 7 }), provider({ name: '  ' }), provider({ canonical_domain: null })] }
    expect(safeProviders(response as never)).toEqual([])
    expect(safeProviders(null)).toEqual([])
    expect(safeProviders({} as never)).toEqual([])
    expect(safeProviders({ providers: 'nope' } as never)).toEqual([])
  })

  it('says which similarly named website it is not', () => {
    const p = only(safeProviders({ providers: [provider({ not_to_be_confused_with: [{ name: 'Escrow Kenya', domain: 'escrowkenya.com' }] })] }))
    expect(p.notToBeConfusedWith).toBe('Not the same company as Escrow Kenya (escrowkenya.com).')
  })

  it('carries a freshness warning, and an approved provider with none has none', () => {
    const stale = only(safeProviders({ providers: [provider({ status: 'approved', freshness: { warnings: ['Pricing is out of date.'] } })] }))
    expect(stale.warning).toBe('Pricing is out of date.')
    const fine = only(safeProviders({ providers: [provider({ status: 'approved', freshness: { warnings: [] } })] }))
    expect(fine.warning).toBeNull()
  })

  it('strips control characters and bounds the length of what it shows', () => {
    const p = only(safeProviders({ providers: [provider({ name: 'Kenya\u0000 Escrow' + 'x'.repeat(200), summaries: { fees: 'a\nb' } })] }))
    expect(p.name).not.toMatch(/\u0000/)
    expect(p.name.length).toBeLessThanOrEqual(60)
    expect(p.feeSummary).toBe('a b')
  })
})

describe('directoryView', () => {
  it('uses the notice the API sent, and always has one', () => {
    expect(directoryView({ providers: [], disclosures: { main: 'From the API.' } }).disclaimer).toBe('From the API.')
    expect(directoryView({ providers: [] }).disclaimer).toBe(REQUIRED_NOTICE)
    expect(directoryView(null).disclaimer).toBe(REQUIRED_NOTICE)
  })

  it('collects the notices about providers that are not listed', () => {
    const view = directoryView({ providers: [], notices: [{ public_notice: 'Escrow Kenya is not on Broka\u2019s list.' }, { public_notice: null }, {}] })
    expect(view.notices).toEqual(['Escrow Kenya is not on Broka\u2019s list.'])
  })

  it('UNAVAILABLE lists nobody - none is better than a stale one - and still has the notice', () => {
    expect(UNAVAILABLE.providers).toEqual([])
    expect(UNAVAILABLE.disclaimer).toBe(REQUIRED_NOTICE)
  })

  it('the required notice is the owner\u2019s wording exactly', () => {
    expect(REQUIRED_NOTICE).toBe(
      "Broka does not operate these escrow services and does not hold, receive or release your money. The services are provided independently by their respective operators. Broka does not guarantee their performance or independently control their funds. Review the provider's current fees, conditions, refund policy and dispute procedures before paying.",
    )
  })
})
