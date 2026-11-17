// Store orders as the API returns them (backend api/domains/store_orders/),
// and the words the storefront puts beside them.
//
// BROKA records an order and what the buyer and the store SAY about paying;
// it never takes, holds or checks the money. So nothing here calls a
// payment "verified" or "secured": a payment record is labelled with who
// reported it (the labels come from the API), and the escrow providers are
// independent services the buyer opens on their own sites.

export type OrderStatus =
  | 'submitted'
  | 'seller_proposed_changes'
  | 'awaiting_buyer_confirmation'
  | 'confirmed'
  | 'preparing'
  | 'ready_for_pickup'
  | 'dispatched'
  | 'delivered'
  | 'completed'
  | 'declined'
  | 'cancelled'
  | 'expired'

export type Fulfilment = 'delivery' | 'collection'

export interface OrderImage {
  id: string
  thumb: string
  medium: string
  large: string
}

export interface OrderItem {
  id: string
  listing_id: string
  name: string
  price_unit: string | null
  image: OrderImage | null
  requested_quantity: number
  requested_unit_price_minor: number
  requested_line_total_minor: number
  proposed_quantity: number | null
  proposed_unit_price_minor: number | null
  final_quantity: number | null
  final_unit_price_minor: number | null
  quantity: number
  unit_price_minor: number
  line_total_minor: number
  changed: boolean
  removed: boolean
}

export interface PaymentReport {
  kind: string
  label: string
  actor_role: 'buyer' | 'seller'
  reference: string | null
  note: string | null
  created_at: string | null
  verified: false
}

export interface OrderPayment {
  arrangement: 'direct_to_seller' | 'independent_escrow' | null
  arrangement_label: string | null
  provider: {
    id: string
    name: string | null
    url: string | null
    domain: string | null
    independent: boolean
    notice: string
  } | null
  reports: PaymentReport[]
  summary: { label: string; awaiting_external_confirmation: boolean; status_note: string | null; verified: false }
  can_choose: boolean
  allowed_reports: string[]
  notice: string
}

export interface OrderEvent {
  id: string
  kind: string
  label: string
  actor_role: 'buyer' | 'seller' | 'system'
  from_status: string | null
  to_status: string | null
  revision: number | null
  detail: Record<string, unknown> | null
  created_at: string | null
}

export interface Order {
  id: string
  reference: string
  role: 'buyer' | 'seller'
  status: OrderStatus
  status_label: string
  open: boolean
  store: { id: string; name: string | null; slug: string | null; url: string | null }
  currency: string
  items: OrderItem[]
  totals: {
    requested_subtotal_minor: number
    seller_subtotal_minor: number | null
    delivery_fee_minor: number | null
    total_minor: number | null
    display_total_minor: number
    final: boolean
  }
  fulfilment: {
    method: Fulfilment
    requested_method: Fulfilment
    address: string | null
    contact_phone: string | null
    note: string | null
    dispatch_note: string | null
  }
  buyer_note: string | null
  seller_note: string | null
  decline_reason: string | null
  cancel_reason: string | null
  cancelled_by: string | null
  problem: { note: string | null; reported_at: string | null } | null
  revision: number
  expires_at: string | null
  expires_in_seconds: number | null
  expiry_stage: 'seller_response' | 'buyer_confirmation' | null
  allowed_actions: string[]
  payment: OrderPayment
  events: OrderEvent[]
  created_at: string | null
  updated_at: string | null
  replayed?: boolean
}

export interface OrderSummary {
  id: string
  reference: string
  status: OrderStatus
  status_label: string
  open: boolean
  needs_action: boolean
  item_count: number
  first_item: string | null
  currency: string
  total_minor: number
  final: boolean
  fulfilment: Fulfilment
  created_at: string | null
  updated_at: string | null
  expires_at: string | null
  store: { id: string; name: string | null; slug: string | null }
}

const kes = new Intl.NumberFormat('en-KE', { minimumFractionDigits: 0, maximumFractionDigits: 2 })

/** "KES 12,500", or "KES 12,500.50" when there are cents. Amounts are
 *  integer cents from the API; the browser never computes a total. */
export function formatMinor(minor: number | null | undefined, currency = 'KES'): string {
  if (minor == null || !Number.isFinite(minor)) return ''
  return `${currency} ${kes.format(minor / 100)}`
}

/** "Thursday 21 Nov, 14:05" in Kenya time. */
export function formatWhen(iso: string | null | undefined): string {
  if (!iso) return ''
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return ''
  return date.toLocaleString('en-KE', {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    hour: '2-digit',
    minute: '2-digit',
    timeZone: 'Africa/Nairobi',
  })
}

/** What a buyer-side button says, by action name. */
export const BUYER_ACTION_LABELS: Record<string, string> = {
  confirm: 'Confirm order',
  reject_proposal: 'Reject the changes',
  cancel: 'Cancel order',
  confirm_received: 'I received it',
  report_problem: 'Report a problem',
}

/** What the buyer's payment-report buttons say. Each one records what the
 *  buyer says they did - BROKA does not see the money. */
export const BUYER_REPORT_BUTTONS: Record<string, string> = {
  buyer_reported_payment_sent: 'Report that I paid the store',
  buyer_reported_escrow_initiated: 'Report that I started the escrow payment',
}

/** The statuses an order ends in without a sale. */
export const UNSUCCESSFUL: readonly OrderStatus[] = ['declined', 'cancelled', 'expired']

/** Short paths in the storefront for order pages (all under /store/, the
 *  only paths broka.co.ke passes to this site - lib/links.ts). */
export const ordersPath = '/store/orders'
export const orderPath = (id: string) => `/store/orders/${encodeURIComponent(id)}`
