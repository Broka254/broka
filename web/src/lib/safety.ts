// What the storefront tells a buyer about paying - all of it, here, so it is
// one file to change when payments come back.
//
// BROKA has paused in-app payments (IN_APP_PAYMENTS_ENABLED is off on the
// server): no escrow provider's API works end to end yet, so BROKA takes no
// buyer's money and the buyer pays the store directly. These pages used to
// promise escrow. Left up, that promise is worse than saying nothing: a
// buyer relies on a safeguard that isn't there, and "pay BROKA escrow at
// this number" is the first line a fraudster would borrow. So every page
// says what is true, the same advice as the app's "Paying safely" sheet
// (flutter_app/lib/features/safe_payment/safe_payment.dart, its text from
// backend/api/domains/pricing/safe_payment.py): you pay the store, you see
// the item first, and where an escrow service is worth its fee there are
// independent ones - never BROKA's.
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
  text: "BROKA doesn't hold payments for now: you pay the store yourself, for example by M-Pesa.",
}

export const SEE_FIRST: Advice = {
  lead: 'See it before you pay.',
  text: 'Meet somewhere public or take delivery, check the item, then pay. Never send a deposit to "hold" an item.',
}

// The providers themselves are listed only in the app, from the server, so
// the list can change without a deploy here - and each sits beside the
// app's note that BROKA doesn't run them.
export const ESCROW_SERVICES: Advice = {
  lead: 'A deal at a distance?',
  text: 'An independent escrow service can hold the money until you have the item; the BROKA app lists some under "Paying safely". They are not run by BROKA.',
}

// Land and cars are not escrow deals: an M-Pesa payment tops out at
// KES 250,000, and only the official search shows who owns the plot or the
// car - the same advice the server gives (backend safe_payment.ADVICE).
export const LAND_AND_CARS: Advice = {
  lead: 'Land or a car?',
  text: 'Do the official search first (Ardhisasa for land, NTSA for the logbook) and pay through a bank or an advocate.',
}

/** The advice in full: the store's details page. */
export const PAYING_SAFELY: readonly Advice[] = [PAY_DIRECT, SEE_FIRST, ESCROW_SERVICES, LAND_AND_CARS]

/** The perks strip's lines about paying (a title, and the line under it);
 *  the first title is the store footer's tag too. */
export const PERK_SEE_FIRST = { title: 'See it, then pay', sub: 'Check the item before any money moves' }
export const PERK_PAY_DIRECT = { title: 'Pay the store directly', sub: 'By M-Pesa, once you have the item' }

/** The rule in a line: the top bar, and with a full stop, link previews.
 *  Short, as the top bar on a 360px phone has room for about this much
 *  beside "Get the app". */
export const PAY_RULE = 'See it, then pay the store'

/** Where a page has room for one line: the cart drawer, the store footer,
 *  the product page. */
export const PAY_LINE = "BROKA doesn't hold payments for now: you pay the store directly, for example by M-Pesa."

export const NO_DEPOSIT = 'Never send a deposit to "hold" an item.'

/** The site's own home page (SiteFooter), which isn't one store's. */
export const SITE_PAY_LINE =
  "BROKA doesn't hold payments for now: you pay the seller directly. See the item before you pay, and never send a deposit to \"hold\" it."
