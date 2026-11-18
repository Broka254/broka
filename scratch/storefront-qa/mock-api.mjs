// TEMPORARY - scratch branch only. A stand-in for the BROKA API with
// fixture data, so the storefront's production build can be driven by a
// browser in CI. No real store, buyer, message or order is involved: every
// name, price and message below is test data. Product pictures are the
// category art the storefront already ships (public/store-assets).
import http from 'node:http'

const PORT = Number(process.env.MOCK_PORT ?? 4010)
const SITE = process.env.SITE_FOR_IMAGES ?? 'http://127.0.0.1:3000'
const TOKEN = 'qa-token'

const art = (p) => `${SITE}/store-assets/category-art/${p}`
const sizes = (id, p) => ({ id, thumb: art(p), medium: art(p), large: art(p) })
const START = Date.now()
const ago = (minutes) => new Date(START - minutes * 60_000).toISOString()

const PAYMENT_NOTICE =
  'BROKA does not receive, hold, verify or release payments for store orders. These are reports made by the buyer or the store, not confirmations from BROKA or from any payment provider.'

const HOURS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'].map((label, i) => ({
  day: label.slice(0, 3).toLowerCase(),
  label,
  short: label.slice(0, 3),
  hours: i === 6 ? 'Closed' : i === 5 ? '09:00 – 16:00' : '08:00 – 18:00',
  closed: i === 6,
  all_day: false,
}))

const owner = (name) => ({
  name,
  verified: true,
  rating: 4.8,
  review_count: 12,
  completed_deals: 37,
  member_since: '2025-01-10T00:00:00',
  online: true,
  last_active: 'Active now',
})

const baseStore = {
  country: 'Kenya',
  business_email: null,
  business_email_verified: false,
  logo: null,
  photo_images: [],
  logo_url: null,
  photos: [],
  is_active: true,
  created_at: '2025-01-10T00:00:00',
  store_type: 'physical',
  opening_hours_week: HOURS,
  opening_hours_available: true,
  open_status: { state: 'open', label: 'Open now · closes 18:00', opens_at: null, closes_at: '18:00', next_day: null },
  orders_enabled: true,
  accepting_orders: true,
  orders_pause_note: null,
}

const STORES = {
  s1: {
    ...baseStore,
    id: 's1',
    name: 'Clanix',
    slug: 'clanix',
    url: 'https://broka.co.ke/store/clanix',
    category: 'Electronics',
    categories: ['Electronics'],
    description:
      'Genuine phones, laptops and accessories in Nairobi CBD. Every phone carries a one-year warranty, and we deliver across Nairobi the same day.',
    county: 'Nairobi',
    subcounty: 'Starehe',
    location_description: 'Moi Avenue, Bazaar Plaza, 2nd floor',
    cover: sizes('cover-s1', 'electronics.webp'),
    owner: owner('Jane Wanjiru'),
    listing_count: 8,
    rating: 8.4,
    review_count: 12,
    response_minutes: 25,
    service_areas: ['Nairobi', 'Kiambu'],
    delivery_note: 'Same-day delivery within Nairobi; next day to Kiambu.',
  },
  s2: {
    ...baseStore,
    id: 's2',
    name: 'Java Home & Living',
    slug: 'java-home',
    url: 'https://broka.co.ke/store/java-home',
    category: 'Home & Furniture',
    categories: ['Home & Furniture'],
    description: 'Sofas, beds and office furniture, made in Thika.',
    county: 'Kiambu',
    subcounty: 'Thika',
    location_description: 'Thika Road, opposite the stadium',
    cover: sizes('cover-s2', 'home-and-furniture.webp'),
    owner: owner('Peter Kamau'),
    listing_count: 3,
    rating: 7.9,
    review_count: 4,
    response_minutes: 60,
    service_areas: ['Kiambu', 'Nairobi'],
    delivery_note: 'Delivery on Tuesdays and Fridays.',
  },
}

const listing = (id, storeId, name, sub, picture, price, over = {}) => {
  const store = STORES[storeId]
  const quantity = over.quantity ?? 3
  const available = over.available_quantity ?? quantity
  return {
    id,
    name,
    category: store.category,
    price,
    price_unit: null,
    quantity,
    status: 'active',
    listing_type: 'buy_now',
    condition: 'new',
    description: null,
    location_name: store.subcounty,
    location_county: store.county,
    location_subcounty: store.subcounty,
    photos: [sizes(`${id}-p`, picture)],
    cover: sizes(`${id}-c`, picture),
    verified_photos: null,
    showcase_image_url: null,
    seller_name: store.owner.name,
    seller_verified: true,
    seller_rating: 4.8,
    seller_review_count: 12,
    seller_completed_deals: 37,
    seller_avg_deal_time_minutes: 1440,
    available: available > 0,
    units_left: available,
    sold_out: available === 0,
    reported_sold_out: false,
    stock_tracked: true,
    available_quantity: available,
    out_of_stock: available === 0,
    temporarily_unavailable: false,
    store_id: store.id,
    store_slug: store.slug,
    store_name: store.name,
    _sub: sub,
    _added: over._added ?? 0,
    ...over,
  }
}

const LISTINGS = [
  listing('l1', 's1', 'Samsung Galaxy A15 · 128 GB', 'phones', 'electronics/phones.webp', 18500, {
    quantity: 5,
    description:
      'Brand new and sealed, 128 GB storage with 4 GB RAM, dual SIM. One-year Samsung Kenya warranty, registered for you at collection or delivery.\n\nIn the box: the phone, a USB-C cable and a SIM tool.',
    _added: 1,
  }),
  listing('l2', 's1', 'HP EliteBook 840 G6 · Core i5, 16 GB', 'laptops', 'electronics/laptops-tablets.webp', 42000, {
    condition: 'refurbished',
    quantity: 2,
    _added: 2,
  }),
  listing('l3', 's1', 'Hisense 43" Full HD smart TV', 'tvs', 'electronics/tvs.webp', 32999, { quantity: 4, _added: 3 }),
  listing('l4', 's1', 'JBL Tune 510BT wireless headphones', 'audio', 'electronics/audio.webp', 5200, { quantity: 7, _added: 4 }),
  listing('l5', 's1', 'Oraimo Watch 2 Pro', 'wearables', 'electronics/wearables.webp', 4300, { quantity: 1, _added: 5 }),
  listing('l6', 's1', 'Canon EOS 2000D with 18–55 mm lens', 'cameras', 'electronics/cameras.webp', 58000, {
    condition: 'used',
    quantity: 1,
    available_quantity: 0,
    _added: 6,
  }),
  listing('l7', 's1', 'Anker 20,000 mAh power bank', 'accessories', 'electronics/power-charging.webp', 3800, { quantity: 9, _added: 7 }),
  listing('l8', 's1', 'TP-Link Archer AX10 Wi-Fi 6 router', 'networking', 'electronics/networking.webp', 7600, { quantity: 3, _added: 8 }),
  listing('j1', 's2', 'Three-seater fabric sofa', 'living', 'home-and-furniture/living-room.webp', 38000, { quantity: 2 }),
  // A listing outside any store: its chat is in the app, never on a store page.
  { ...listing('out1', 's1', 'Toyota Probox 2014', 'cars', 'automobiles.webp', 950000), store_id: null, store_slug: null, store_name: null },
]

const CATEGORIES = {
  s1: [
    {
      name: 'Electronics',
      count: 8,
      subcategories: [
        { id: 'phones', name: 'Phones', count: 1 },
        { id: 'laptops', name: 'Laptops & Computers', count: 1 },
        { id: 'tvs', name: 'TVs', count: 1 },
        { id: 'audio', name: 'Audio', count: 1 },
        { id: 'wearables', name: 'Smartwatches & Wearables', count: 1 },
        { id: 'cameras', name: 'Cameras', count: 1 },
        { id: 'accessories', name: 'Accessories', count: 1 },
        { id: 'networking', name: 'Networking', count: 1 },
      ],
    },
  ],
  s2: [{ name: 'Home & Furniture', count: 3 }],
}

const REVIEWS = {
  summary: { avg: 4.7, count: 3, distribution: { 5: 2, 4: 1, 3: 0, 2: 0, 1: 0 } },
  reviews: [
    { id: 'r1', rating: 5, comment: 'Phone exactly as described, delivered the same afternoon.', created_at: ago(60 * 24 * 9), reviewer_name: 'Amina W.' },
    { id: 'r2', rating: 5, comment: 'Helpful on WhatsApp and here. Good prices.', created_at: ago(60 * 24 * 20), reviewer_name: 'Brian O.' },
    { id: 'r3', rating: 4, comment: 'Laptop works well; delivery took a day longer than promised.', created_at: ago(60 * 24 * 41), reviewer_name: 'Grace M.' },
  ],
  seller_standing: { overall_rating: 8.5, dcr: null, dcr_provisional: false, median_response_minutes: 25, completed_deals: 37, as_of: ago(60 * 24) },
}

const ESCROW = {
  providers: [
    {
      id: 'qa-escrow',
      name: 'Example Escrow (test data)',
      status: 'under_review',
      review_label: 'Under review: a test fixture, not a real provider',
      website_url: 'https://escrow.example.com/',
      canonical_domain: 'escrow.example.com',
      summaries: { fees: 'Test fixture - no real fees', limits: '', requirements: '' },
      freshness: { warnings: ['A test fixture: not a real escrow provider.'] },
      not_to_be_confused_with: [],
    },
  ],
}

const USER = { id: 'u1', name: 'Amina Wanjiru', phone: '+254712345678' }

// ── Conversations: the buyer's threads, oldest message first ───────────────
let counter = 0
const msg = (role, content, minutesAgo, extra = {}) => ({
  id: `m${++counter}`,
  role,
  content,
  via_ai: false,
  msg_type: 'text',
  created_at: ago(minutesAgo),
  client_msg_id: null,
  ...extra,
})

const THREADS = {
  'product:l1': [
    msg('buyer', 'Hi, is the Galaxy A15 still available?', 1500),
    msg('seller', 'Hello Amina! Yes, we have five in stock - black and light blue.', 1496),
    msg('buyer', 'Is it the 128 GB one?', 1494),
    msg('buyer', 'And does it come with a charger?', 1493),
    msg('seller', 'Yes, 128 GB with 4 GB RAM. The box has a cable; the charger is sold separately (KES 900).', 1480),
    msg('buyer', 'Okay. Is there a warranty?', 1300),
    msg('seller', 'One year, from Samsung Kenya. We register it for you when you collect or when we deliver.', 1290),
    msg('buyer', 'Great. Can you deliver to Kilimani today?', 185),
    msg('seller', 'Yes - delivery to Kilimani is KES 300, usually within 3 hours.', 176),
    msg('buyer', 'Perfect.', 170),
    msg('buyer', "I'll send the order from the cart now.", 169),
    msg('seller', "Thank you! We'll confirm it as soon as it comes in.", 160),
    msg('seller', 'Your order is confirmed on our side - please check the total and confirm it.', 42),
  ],
  'store:s1': [
    msg('buyer', 'Hello, do you have the iPhone 13?', 60 * 24 * 4),
    msg('seller', 'Not at the moment - we expect stock next week.', 60 * 24 * 4 - 20),
    msg('buyer', 'Okay, thanks!', 60 * 24 * 4 - 22),
  ],
  'product:l3': [
    msg('buyer', 'Does the TV come with a wall bracket?', 60 * 26),
    msg('seller', 'It comes with the stand; a wall bracket is KES 1,500 and we can fit it.', 60 * 25),
  ],
  'store:s2': [
    msg('buyer', 'Do you deliver to Thika town?', 60 * 50),
    msg('seller', 'Yes, every Tuesday and Friday. Delivery is KES 500.', 60 * 49),
  ],
}

function push(thread, role, content, clientId = null) {
  const list = (THREADS[thread] ??= [])
  const m = { id: `m${++counter}`, role, content, via_ai: false, msg_type: 'text', created_at: new Date().toISOString(), client_msg_id: clientId }
  list.push(m)
  return m
}

let failNext = false

function inbox() {
  const rows = []
  for (const [key, messages] of Object.entries(THREADS)) {
    const last = messages.at(-1)
    if (!last) continue
    const [kind, id] = key.split(':')
    const common = {
      my_role: 'buyer',
      last_message: last.content,
      last_role: last.role,
      last_msg_type: 'text',
      last_message_id: last.id,
      last_message_at: last.created_at,
      unread: last.role === 'seller' ? 1 : 0,
      time_ago: '1h ago',
    }
    if (kind === 'store') rows.push({ ...common, thread_type: 'store', store_id: id, listing_id: null, store_name: STORES[id].name })
    else rows.push({ ...common, listing_id: id, listing_name: LISTINGS.find((l) => l.id === id)?.name })
  }
  // What the website must leave out: a listing outside any store, and the
  // seller's side of a store this user would own.
  rows.push({ listing_id: 'out1', my_role: 'buyer', last_message: 'Is the Probox still for sale?', last_role: 'buyer', last_msg_type: 'text', last_message_at: ago(60 * 70) })
  rows.push({ listing_id: 'l2', my_role: 'seller', last_message: 'Hi', last_role: 'buyer', last_msg_type: 'text', last_message_at: ago(5) })
  return rows.sort((a, b) => String(b.last_message_at).localeCompare(String(a.last_message_at)))
}

// ── Orders ──────────────────────────────────────────────────────────────────
const item = (id, l, qty, unitMinor, over = {}) => ({
  id,
  listing_id: l.id,
  name: l.name,
  price_unit: null,
  image: { id: `${l.id}-c`, thumb: l.cover.thumb, medium: l.cover.medium, large: l.cover.large },
  requested_quantity: qty,
  requested_unit_price_minor: unitMinor,
  requested_line_total_minor: qty * unitMinor,
  proposed_quantity: null,
  proposed_unit_price_minor: null,
  final_quantity: null,
  final_unit_price_minor: null,
  quantity: qty,
  unit_price_minor: unitMinor,
  line_total_minor: qty * unitMinor,
  changed: false,
  removed: false,
  ...over,
})

const byId = (id) => LISTINGS.find((l) => l.id === id)

function order(id, reference, storeId, status, label, over = {}) {
  const store = STORES[storeId]
  return {
    id,
    reference,
    role: 'buyer',
    status,
    status_label: label,
    open: !['completed', 'declined', 'cancelled', 'expired'].includes(status),
    store: { id: store.id, name: store.name, slug: store.slug, url: store.url },
    currency: 'KES',
    items: [],
    totals: { requested_subtotal_minor: 0, seller_subtotal_minor: null, delivery_fee_minor: null, total_minor: null, display_total_minor: 0, final: false },
    fulfilment: { method: 'delivery', requested_method: 'delivery', address: 'Kilimani, opposite Yaya Centre', contact_phone: USER.phone, note: null, dispatch_note: null },
    buyer_note: null,
    seller_note: null,
    decline_reason: null,
    cancel_reason: null,
    cancelled_by: null,
    problem: null,
    revision: 1,
    expires_at: null,
    expires_in_seconds: null,
    expiry_stage: null,
    allowed_actions: [],
    payment: {
      arrangement: null,
      arrangement_label: null,
      provider: null,
      reports: [],
      summary: { label: 'No payment arrangement chosen yet', awaiting_external_confirmation: false, status_note: null, verified: false },
      can_choose: false,
      allowed_reports: [],
      notice: PAYMENT_NOTICE,
    },
    events: [],
    created_at: ago(170),
    updated_at: ago(42),
    ...over,
  }
}

const ORDERS = {
  o1: order('o1', 'BK-7Q2M9XKD', 's1', 'awaiting_buyer_confirmation', 'The store confirmed - your turn to confirm', {
    items: [
      item('i1', byId('l1'), 1, 1_850_000),
      item('i2', byId('l7'), 2, 380_000, {
        proposed_quantity: 1,
        quantity: 1,
        line_total_minor: 380_000,
        changed: true,
      }),
    ],
    totals: {
      requested_subtotal_minor: 2_610_000,
      seller_subtotal_minor: 2_230_000,
      delivery_fee_minor: 30_000,
      total_minor: 2_260_000,
      display_total_minor: 2_260_000,
      final: false,
    },
    fulfilment: {
      method: 'delivery',
      requested_method: 'delivery',
      address: 'Kilimani, opposite Yaya Centre',
      contact_phone: USER.phone,
      note: 'Delivered within 3 hours of your confirmation.',
      dispatch_note: null,
    },
    seller_note: 'Only one power bank left - the rest of the order is as you asked.',
    revision: 2,
    expires_at: new Date(START + 20 * 3600_000).toISOString(),
    expires_in_seconds: 20 * 3600,
    expiry_stage: 'buyer_confirmation',
    allowed_actions: ['confirm', 'reject_proposal', 'cancel'],
    payment: {
      arrangement: null,
      arrangement_label: null,
      provider: null,
      reports: [],
      summary: { label: 'No payment arrangement chosen yet', awaiting_external_confirmation: false, status_note: null, verified: false },
      can_choose: true,
      allowed_reports: [],
      notice: PAYMENT_NOTICE,
    },
    events: [
      { id: 'e1', kind: 'submitted', label: 'Order request sent', actor_role: 'buyer', from_status: null, to_status: 'submitted', revision: 1, detail: null, created_at: ago(168) },
      {
        id: 'e2',
        kind: 'accepted',
        label: 'The store confirmed, with changes',
        actor_role: 'seller',
        from_status: 'submitted',
        to_status: 'awaiting_buyer_confirmation',
        revision: 2,
        detail: { changes: [{ item: 'Anker 20,000 mAh power bank', from_quantity: 2, to_quantity: 1 }] },
        created_at: ago(42),
      },
    ],
  }),
  o2: order('o2', 'BK-3HD8WQ2P', 's2', 'preparing', 'Being prepared', {
    items: [item('i3', byId('j1'), 1, 3_800_000)],
    totals: { requested_subtotal_minor: 3_800_000, seller_subtotal_minor: 3_800_000, delivery_fee_minor: 50_000, total_minor: 3_850_000, display_total_minor: 3_850_000, final: true },
    created_at: ago(60 * 30),
    updated_at: ago(60 * 5),
  }),
  o3: order('o3', 'BK-9KXT4MZA', 's1', 'completed', 'Completed', {
    items: [item('i4', byId('l4'), 1, 520_000)],
    totals: { requested_subtotal_minor: 520_000, seller_subtotal_minor: 520_000, delivery_fee_minor: 0, total_minor: 520_000, display_total_minor: 520_000, final: true },
    created_at: ago(60 * 24 * 12),
    updated_at: ago(60 * 24 * 10),
  }),
  o4: order('o4', 'BK-2PLV7RNE', 's1', 'declined', 'Declined by the store', {
    items: [item('i5', byId('l6'), 1, 5_800_000)],
    totals: { requested_subtotal_minor: 5_800_000, seller_subtotal_minor: null, delivery_fee_minor: null, total_minor: null, display_total_minor: 5_800_000, final: false },
    decline_reason: 'Sold in the shop before your request came in.',
    created_at: ago(60 * 24 * 6),
    updated_at: ago(60 * 24 * 6 - 30),
  }),
}

function summary(o) {
  return {
    id: o.id,
    reference: o.reference,
    status: o.status,
    status_label: o.status_label,
    open: o.open,
    needs_action: o.allowed_actions.includes('confirm') || o.allowed_actions.includes('confirm_received'),
    item_count: o.items.length,
    first_item: o.items[0]?.name ?? null,
    currency: o.currency,
    total_minor: o.totals.display_total_minor,
    final: o.totals.final,
    fulfilment: o.fulfilment.method,
    created_at: o.created_at,
    updated_at: o.updated_at,
    expires_at: o.expires_at,
    store: { id: o.store.id, name: o.store.name, slug: o.store.slug },
  }
}

// ── The server ──────────────────────────────────────────────────────────────
const signedIn = (req) => req.headers.authorization === `Bearer ${TOKEN}`
const SIGNED_OUT = [401, { detail: 'Could not validate credentials' }]
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const publicListing = ({ _sub, _added, ...l }) => l // eslint-disable-line no-unused-vars

const routes = [
  ['GET', /^\/__qa\/health$/, () => [200, { ok: true }]],
  ['POST', /^\/__qa\/reply$/, (m, q, body) => [200, push(body.thread, 'seller', body.content)]],
  [
    'POST',
    /^\/__qa\/fail-next$/,
    () => {
      failNext = true
      return [200, { ok: true }]
    },
  ],
  ['GET', /^\/stores\/slug\/([a-z0-9-]+)$/, (m) => {
    const s = Object.values(STORES).find((x) => x.slug === m[1])
    return s ? [200, s] : [404, { detail: 'Store not found' }]
  }],
  ['GET', /^\/stores\/([\w-]+)\/categories$/, (m) => [200, CATEGORIES[m[1]] ?? []]],
  ['GET', /^\/stores\/([\w-]+)\/reviews$/, () => [200, REVIEWS]],
  ['GET', /^\/stores\/([\w-]+)\/listings$/, (m, q) => {
    let rows = LISTINGS.filter((l) => l.store_id === m[1])
    const search = (q.get('search') ?? '').toLowerCase()
    if (search) rows = rows.filter((l) => l.name.toLowerCase().includes(search))
    const sub = q.get('subcategory_id')
    if (sub) rows = rows.filter((l) => l._sub === sub)
    const condition = q.get('condition')
    if (condition) rows = rows.filter((l) => l.condition === condition)
    const sort = q.get('sort')
    if (sort === 'newest') rows = [...rows].sort((a, b) => b._added - a._added)
    if (sort === 'price_low') rows = [...rows].sort((a, b) => a.price - b.price)
    if (sort === 'price_high') rows = [...rows].sort((a, b) => b.price - a.price)
    const offset = Number(q.get('offset') ?? 0)
    const limit = Number(q.get('limit') ?? 24)
    return [200, rows.slice(offset, offset + limit).map(publicListing)]
  }],
  ['POST', /^\/stores\/([\w-]+)\/(visit|share|cart-events|campaign\/.+)$/, () => [204, null]],
  ['POST', /^\/stores\/([\w-]+)\/enquiries$/, async (m, q, body, req) => {
    if (!signedIn(req)) return SIGNED_OUT
    if (failNext) {
      failNext = false
      return [429, { detail: 'Too many store_enquiry attempts. Limit: 12 per 600s.' }]
    }
    // Long enough for a screenshot of "Sending...".
    await sleep(1600)
    const thread = body.listing_id ? `product:${body.listing_id}` : `store:${m[1]}`
    const earlier = (THREADS[thread] ?? []).find((x) => body.client_msg_id && x.client_msg_id === body.client_msg_id)
    const stored = earlier ?? push(thread, 'buyer', String(body.content ?? '').trim(), body.client_msg_id ?? null)
    return [201, { ok: true, message: { ...stored, deleted: false } }]
  }],
  ['GET', /^\/stores\/([\w-]+)$/, (m) => (STORES[m[1]] ? [200, STORES[m[1]]] : [404, { detail: 'Store not found' }])],
  ['GET', /^\/listings\/([\w-]+)$/, (m) => {
    const l = byId(m[1])
    return l ? [200, publicListing(l)] : [404, { detail: 'Listing not found' }]
  }],
  ['GET', /^\/escrow-providers$/, () => [200, ESCROW]],
  ['GET', /^\/auth\/me$/, (m, q, b, req) => (signedIn(req) ? [200, USER] : SIGNED_OUT)],
  ['POST', /^\/auth\/token\/(refresh|revoke)$/, () => [401, { detail: 'Refresh token invalid' }]],
  ['GET', /^\/negotiate\/inbox\/([\w-]+)$/, (m, q, b, req) => {
    if (!signedIn(req)) return SIGNED_OUT
    if (m[1] !== USER.id) return [403, { detail: "Cannot access another user's inbox." }]
    return [200, inbox()]
  }],
  ['GET', /^\/negotiate\/store\/([\w-]+)\/history$/, (m, q, b, req) => (signedIn(req) ? [200, THREADS[`store:${m[1]}`] ?? []] : SIGNED_OUT)],
  ['GET', /^\/negotiate\/([\w-]+)\/history$/, (m, q, b, req) => (signedIn(req) ? [200, THREADS[`product:${m[1]}`] ?? []] : SIGNED_OUT)],
  ['GET', /^\/orders$/, (m, q, b, req) => {
    if (!signedIn(req)) return SIGNED_OUT
    const scope = q.get('scope') ?? 'open'
    const all = Object.values(ORDERS).sort((a, b) => String(b.updated_at).localeCompare(String(a.updated_at)))
    const items = all.filter((o) => (scope === 'all' ? true : scope === 'open' ? o.open : !o.open)).map(summary)
    return [200, { items, total: items.length }]
  }],
  ['POST', /^\/orders\/notifications\/read$/, () => [200, { marked: 1 }]],
  ['GET', /^\/orders\/([\w-]+)$/, (m, q, b, req) => {
    if (!signedIn(req)) return SIGNED_OUT
    return ORDERS[m[1]] ? [200, ORDERS[m[1]]] : [404, { detail: { code: 'ORDER_NOT_FOUND', message: 'Order not found' } }]
  }],
]

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`)
  let raw = ''
  for await (const chunk of req) raw += chunk
  let body = {}
  try {
    body = raw ? JSON.parse(raw) : {}
  } catch {
    body = {}
  }
  const route = routes.find(([method, pattern]) => method === req.method && pattern.test(url.pathname))
  let status = 404
  let data = { detail: 'Not found (mock)' }
  if (route) [status, data] = await route[2](url.pathname.match(route[1]), url.searchParams, body, req)
  console.log(`${req.method} ${url.pathname}${url.search} -> ${status}`)
  if (data === null) {
    res.writeHead(status)
    res.end()
    return
  }
  res.writeHead(status, { 'content-type': 'application/json' })
  res.end(JSON.stringify(data))
})

server.listen(PORT, '127.0.0.1', () => console.log(`mock BROKA API on ${PORT}`))
