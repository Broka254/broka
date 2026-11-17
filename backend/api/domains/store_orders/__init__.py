"""Store orders: a buyer's request to buy products from one store, and what
happens to it until it is fulfilled or ends.

BROKA COORDINATES AN ORDER; IT NEVER HANDLES ITS MONEY
======================================================
BROKA is not a payment processor, wallet or escrow holder, and nothing in
this package moves, holds, verifies or releases money. An order records
what the buyer asked for, what the seller confirmed, how the goods change
hands and - separately - what each side *says* about paying: directly to the
seller, or through an independent escrow provider the buyer chose from
BROKA's directory (api/domains/escrow_directory). Those payment reports are
labelled as reported by a person, never as verified, and no payment report
moves an order forward: fulfilment and payment are separate concerns.

  lifecycle.py   the order state machine and the payment-report rules (pure)
  pricing.py     money in integer minor units, totals, what counts as a change (pure)
  messages.py    the words of each notification (pure)
  stock.py       reserving, releasing and deducting tracked stock (atomic SQL)
  service.py     creating orders and applying actions, one transaction each
  notify.py      the in-app feed and its push delivery, after the commit
  analytics.py   the order funnel for store insights and campaign attribution
  router.py      the HTTP contracts

STORE_ORDERS.md (repository root) describes the design end to end.
"""
