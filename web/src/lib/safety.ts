// What the storefront tells a buyer about paying - all of it, here, so it is
// one file to change when payments come back.
//
// BROKA has paused in-app payments (IN_APP_PAYMENTS_ENABLED is off on the
// server): no escrow provider's API works end to end yet, so BROKA takes no
// buyer's money and the buyer pays the store directly. These pages used to
// promise escrow. Left up, that promise is worse than saying nothing: a
// buyer relies on a safeguard that isn't there, and "pay BROKA escrow at
// this number" is the first line a fraudster would borrow. So every page
// says what is true, the same advice as the app's "Pay with escrow" screen
// (flutter_app/lib/features/safe_payment/, its text from
// backend/api/domains/pricing/safe_payment.py): you pay the store, through
// an independent escrow service when you can't see the item first - never
// BROKA's - or once you have seen it.
//
// For launch (2026-10-08) escrow comes first: a store's buyer is often in
// another town and can't see the item before paying, so every page that
// takes a buyer towards paying shows the escrow services BROKA lists
// (EscrowBox.tsx), and that Zeno, in the app, walks them through one step by
// step. THE LIST ITSELF IS NOT HERE (2026-11): it is the API's, fetched by
// each page (lib/escrow-providers.ts). A copy typed in here could not be
// corrected without a deploy, could not say a provider was suspended, and
// still named escrowkenya.com as an active service.
//
// What is still true is still said where it was: delivery or pickup is
// agreed with the store, and Zeno carries questions and offers between buyer
// and seller. Tied to the pause outside this file: the cart page's Payment
// row, its button into the app and its note for other phones
// (CheckoutView.tsx). A test (components.test.tsx, "Paying") reads every
// page for the old promises, so one can't come back by accident while
// payments are paused.

/** One piece of advice: a bold lead, then the rest. */
export interface Advice {
  lead: string
  text: string
}

export const PAY_DIRECT: Advice = {
  lead: 'Pay the store directly.',
  text: "BROKA doesn't hold payments for now: you pay the store yourself - through an escrow service, or by M-Pesa once you have the item.",
}

export const SEE_FIRST: Advice = {
  lead: 'See it before you pay.',
  text: 'Meet somewhere public or take delivery, check the item, then pay. Never send a deposit to "hold" an item.',
}

export const ESCROW_SERVICES: Advice = {
  lead: 'A deal at a distance?',
  text: 'Pay through an independent escrow service: under its own rules, it can hold the payment until you have the item. They are not run by BROKA, and protection depends on each one\'s terms.',
}

// Land and cars are not escrow deals: an M-Pesa payment tops out at
// KES 250,000, and only the official search shows who owns the plot or the
// car - the same advice the server gives (backend safe_payment.ADVICE).
export const LAND_AND_CARS: Advice = {
  lead: 'Land or a car?',
  text: 'Do the official search first (Ardhisasa for land, NTSA for the logbook) and pay through a bank or an advocate.',
}

/** The advice in full: the store's details page. */
export const PAYING_SAFELY: readonly Advice[] = [PAY_DIRECT, ESCROW_SERVICES, SEE_FIRST, LAND_AND_CARS]

/** The rule a fake escrow site depends on breaking. */
export const OPEN_IT_YOURSELF =
  "Open the escrow service yourself from this list. Never use an escrow link, paybill or 'agent' the store sends you - fake escrow sites are a common scam."

export const ZENO_ESCROW = 'Never used escrow? Zeno, in the BROKA app, walks you through it one step at a time.'

/** The perks strip's lines about paying (a title, and the line under it);
 *  the first title is the store footer's tag too. */
export const PERK_SEE_FIRST = { title: 'See it, then pay', sub: 'Check the item before any money moves' }
export const PERK_PAY_DIRECT = { title: 'Pay the store directly', sub: 'Through escrow, or by M-Pesa once you have it' }

/** The rule in a line: the top bar, and with a full stop, link previews.
 *  Short, as the top bar on a 360px phone has room for about this much
 *  beside "Get the app". */
export const PAY_RULE = 'See it, then pay the store'

/** Where a page has room for one line: the cart drawer, the store footer,
 *  the product page. */
export const PAY_LINE =
  "BROKA doesn't hold payments for now: pay the store through an independent escrow service, or by M-Pesa once you have the item."

export const NO_DEPOSIT = 'Never send a deposit to "hold" an item.'

/** The site's own home page (SiteFooter), which isn't one store's. */
export const SITE_PAY_LINE =
  "BROKA doesn't hold payments for now: pay the seller through an independent escrow service, or see the item before you pay - and never send a deposit to \"hold\" it."
