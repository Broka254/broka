// Store orders, as the app reads them (backend api/domains/store_orders/):
// an order request a buyer sent a store, the store's answer, the buyer's
// confirmation, the handover, and what each side reports about paying.
//
// The server is the only source of every status, price and total: these
// classes parse what it sends and never work a total out themselves.
//
// BROKA records the order and what the buyer and the store SAY about
// paying. It never receives, holds, checks or releases the money, so
// nothing here - or on a screen built from it - calls a payment verified:
// a report is labelled with who made it.
import '../../../../utils/backend_time.dart';
import '../../../../utils/price_format.dart';

int _int(Object? v) => (v as num?)?.toInt() ?? 0;
int? _intOrNull(Object? v) => (v as num?)?.toInt();
String? _text(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

/// "KES 12,500", or "KES 12,500.50" when there are cents. The API sends
/// integer cents (minor units) for every amount.
String formatMinorKes(int? minor) {
  if (minor == null) return '';
  // Amounts are never negative; `%` on two ints is an int.
  final whole = minor ~/ 100;
  final cents = minor % 100;
  if (cents == 0) return formatKes(whole);
  return 'KES ${formatKesAmount(whole)}.${cents.toString().padLeft(2, '0')}';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "17 Nov, 14:05" on the phone's clock, or '' when there is no time.
String formatOrderWhen(DateTime? utc) {
  if (utc == null) return '';
  final d = utc.toLocal();
  final hh = d.hour.toString().padLeft(2, '0');
  final mm = d.minute.toString().padLeft(2, '0');
  return '${d.day} ${_months[d.month - 1]}, $hh:$mm';
}

/// Where an order is (backend lifecycle.STATUSES).
enum StoreOrderStatus {
  submitted('submitted'),
  sellerProposedChanges('seller_proposed_changes'),
  awaitingBuyerConfirmation('awaiting_buyer_confirmation'),
  confirmed('confirmed'),
  preparing('preparing'),
  readyForPickup('ready_for_pickup'),
  dispatched('dispatched'),
  delivered('delivered'),
  completed('completed'),
  declined('declined'),
  cancelled('cancelled'),
  expired('expired'),

  /// A status from a newer backend this app does not know: shown by the
  /// server's label, and never acted on.
  unknown('unknown');

  const StoreOrderStatus(this.value);

  /// The backend's name for it.
  final String value;

  static StoreOrderStatus parse(Object? value) {
    for (final s in StoreOrderStatus.values) {
      if (s.value == value) return s;
    }
    return StoreOrderStatus.unknown;
  }

  /// The order ended without a sale.
  bool get endedWithoutSale =>
      this == StoreOrderStatus.declined ||
      this == StoreOrderStatus.cancelled ||
      this == StoreOrderStatus.expired;
}

/// Something a person can do to an order, as the API names it in
/// `allowed_actions` (backend lifecycle.ACTIONS), with the path it is
/// posted to (POST /orders/{id}/{path}).
enum StoreOrderAction {
  // The store's.
  accept('accept', 'accept'),
  propose('propose', 'propose'),
  decline('decline', 'decline'),
  startPreparing('start_preparing', 'preparing'),
  markReady('mark_ready', 'ready'),
  dispatch('dispatch', 'dispatch'),
  markDelivered('mark_delivered', 'delivered'),
  // Either side's: the API answers "cancel" with the rule for the caller.
  cancel('cancel', 'cancel'),
  // The buyer's.
  confirm('confirm', 'confirm'),
  rejectProposal('reject_proposal', 'reject-proposal'),
  confirmReceived('confirm_received', 'received'),
  reportProblem('report_problem', 'problem');

  const StoreOrderAction(this.value, this.path);
  final String value;
  final String path;

  /// Null for an action this app does not know: it is not offered.
  static StoreOrderAction? parse(Object? value) {
    for (final a in StoreOrderAction.values) {
      if (a.value == value) return a;
    }
    return null;
  }
}

/// The groups the store's order list is filtered by (backend
/// lifecycle.SELLER_GROUPS), in the order an owner works through them.
enum StoreOrderGroup {
  needsAction('needs_action', 'To do'),
  awaitingBuyer('awaiting_buyer', 'Waiting on the buyer'),
  handedOver('ready_or_dispatched', 'Ready or on the way'),
  completed('completed', 'Completed'),
  closed('closed', 'Declined, cancelled or expired');

  const StoreOrderGroup(this.value, this.label);
  final String value;
  final String label;
}

/// One product in an order: what the buyer asked for, what the store
/// offers, and - once the buyer confirmed - what was agreed.
class StoreOrderItem {
  const StoreOrderItem({
    required this.id,
    required this.listingId,
    required this.name,
    this.priceUnit,
    required this.requestedQuantity,
    required this.requestedUnitPriceMinor,
    this.proposedQuantity,
    this.proposedUnitPriceMinor,
    this.finalQuantity,
    required this.quantity,
    required this.unitPriceMinor,
    required this.lineTotalMinor,
    this.changed = false,
    this.removed = false,
    this.stockTracked = false,
    this.stockOnHand,
    this.stockAvailable,
    this.stockInDeals,
    this.reservedQuantity = 0,
  });

  final String id;
  final String listingId;
  final String name;
  final String? priceUnit;
  final int requestedQuantity;
  final int requestedUnitPriceMinor;
  final int? proposedQuantity;
  final int? proposedUnitPriceMinor;
  final int? finalQuantity;

  /// The figures to show now: the agreed ones once confirmed, else the
  /// store's offer, else the buyer's request.
  final int quantity;
  final int unitPriceMinor;
  final int lineTotalMinor;

  /// The store's offer differs from the request.
  final bool changed;

  /// The store can't supply this product (quantity 0).
  final bool removed;

  // The store's own view only (null or zero for the buyer). The backend's
  // shared count (listings/inventory.py), counted by the store or not:
  // [stockAvailable] is what another order or a chat deal may still take,
  // with units in chat deals ([stockInDeals]) and other orders'
  // reservations already off. [stockOnHand] only when the store counts.
  final bool stockTracked;
  final int? stockOnHand;
  final int? stockAvailable;
  final int? stockInDeals;
  final int reservedQuantity;

  bool get quantityChanged => proposedQuantity != null && proposedQuantity != requestedQuantity;
  bool get priceChanged =>
      proposedUnitPriceMinor != null && proposedUnitPriceMinor != requestedUnitPriceMinor;

  factory StoreOrderItem.fromJson(Map<String, dynamic> j) => StoreOrderItem(
        id: j['id'] as String? ?? '',
        listingId: j['listing_id'] as String? ?? '',
        name: _text(j['name']) ?? 'A product',
        priceUnit: _text(j['price_unit']),
        requestedQuantity: _int(j['requested_quantity']),
        requestedUnitPriceMinor: _int(j['requested_unit_price_minor']),
        proposedQuantity: _intOrNull(j['proposed_quantity']),
        proposedUnitPriceMinor: _intOrNull(j['proposed_unit_price_minor']),
        finalQuantity: _intOrNull(j['final_quantity']),
        quantity: _int(j['quantity']),
        unitPriceMinor: _int(j['unit_price_minor']),
        lineTotalMinor: _int(j['line_total_minor']),
        changed: j['changed'] == true,
        removed: j['removed'] == true,
        stockTracked: j['stock_tracked'] == true,
        stockOnHand: _intOrNull(j['stock_on_hand']),
        stockAvailable: _intOrNull(j['stock_available']),
        stockInDeals: _intOrNull(j['stock_committed_to_deals']),
        reservedQuantity: _int(j['reserved_quantity']),
      );
}

/// What one side said about paying. Never a confirmation from BROKA.
class StoreOrderPaymentReport {
  const StoreOrderPaymentReport({
    required this.kind,
    required this.label,
    required this.actorRole,
    this.reference,
    this.note,
    this.createdAt,
  });

  final String kind;

  /// The server's label: "Buyer reported payment sent", "Seller confirmed
  /// receipt", and so on - it says who reported it.
  final String label;

  /// "buyer" or "seller".
  final String actorRole;
  final String? reference;
  final String? note;
  final DateTime? createdAt;

  factory StoreOrderPaymentReport.fromJson(Map<String, dynamic> j) => StoreOrderPaymentReport(
        kind: j['kind'] as String? ?? '',
        label: _text(j['label']) ?? 'Payment reported',
        actorRole: j['actor_role'] as String? ?? '',
        reference: _text(j['reference']),
        note: _text(j['note']),
        createdAt: parseBackendUtc(j['created_at'] as String?),
      );
}

/// How the buyer pays the store, and what each side has reported.
class StoreOrderPayment {
  const StoreOrderPayment({
    this.arrangement,
    this.arrangementLabel,
    this.providerName,
    this.providerUrl,
    this.providerDomain,
    this.providerNotice,
    this.reports = const [],
    this.summaryLabel = '',
    this.awaitingExternalConfirmation = false,
    this.statusNote,
    this.allowedReports = const [],
    this.notice = '',
  });

  /// "direct_to_seller" or "independent_escrow"; null until the buyer chose.
  final String? arrangement;
  final String? arrangementLabel;

  /// An independent escrow provider the buyer chose from BROKA's directory.
  /// It is not BROKA, and [providerNotice] says so.
  final String? providerName;
  final String? providerUrl;
  final String? providerDomain;
  final String? providerNotice;

  final List<StoreOrderPaymentReport> reports;
  final String summaryLabel;
  final bool awaitingExternalConfirmation;
  final String? statusNote;

  /// The report kinds the caller may make now.
  final List<String> allowedReports;

  /// What the record is and is not, from the server: shown wherever it is.
  final String notice;

  factory StoreOrderPayment.fromJson(Object? json) {
    if (json is! Map) return const StoreOrderPayment();
    final j = json.cast<String, dynamic>();
    final provider = (j['provider'] as Map?)?.cast<String, dynamic>();
    final summary = (j['summary'] as Map?)?.cast<String, dynamic>() ?? const {};
    return StoreOrderPayment(
      arrangement: _text(j['arrangement']),
      arrangementLabel: _text(j['arrangement_label']),
      providerName: _text(provider?['name']),
      providerUrl: _text(provider?['url']),
      providerDomain: _text(provider?['domain']),
      providerNotice: _text(provider?['notice']),
      reports: [
        for (final r in j['reports'] as List? ?? const [])
          if (r is Map) StoreOrderPaymentReport.fromJson(r.cast<String, dynamic>()),
      ],
      summaryLabel: _text(summary['label']) ?? '',
      awaitingExternalConfirmation: summary['awaiting_external_confirmation'] == true,
      statusNote: _text(summary['status_note']),
      allowedReports: (j['allowed_reports'] as List?)?.whereType<String>().toList() ?? const [],
      notice: _text(j['notice']) ?? '',
    );
  }
}

/// One thing that happened to an order.
class StoreOrderEvent {
  const StoreOrderEvent({
    required this.id,
    required this.kind,
    required this.label,
    required this.actorRole,
    this.createdAt,
    this.detail = const {},
  });

  final String id;
  final String kind;
  final String label;

  /// "buyer", "seller" or "system".
  final String actorRole;
  final DateTime? createdAt;
  final Map<String, dynamic> detail;

  /// The reason or note that came with it, if any.
  String? get note => _text(detail['reason']) ?? _text(detail['note']);

  factory StoreOrderEvent.fromJson(Map<String, dynamic> j) => StoreOrderEvent(
        id: j['id'] as String? ?? '',
        kind: j['kind'] as String? ?? '',
        label: _text(j['label']) ?? 'Updated',
        actorRole: j['actor_role'] as String? ?? '',
        createdAt: parseBackendUtc(j['created_at'] as String?),
        detail: (j['detail'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}

/// One order, as GET /orders/{id} and every action return it.
class StoreOrder {
  const StoreOrder({
    required this.id,
    required this.reference,
    required this.role,
    required this.status,
    required this.statusLabel,
    this.open = true,
    this.storeId = '',
    this.storeName,
    this.storeUrl,
    this.currency = 'KES',
    this.items = const [],
    this.requestedSubtotalMinor = 0,
    this.sellerSubtotalMinor,
    this.deliveryFeeMinor,
    this.totalMinor,
    this.displayTotalMinor = 0,
    this.isFinal = false,
    this.fulfilment = 'delivery',
    this.requestedFulfilment = 'delivery',
    this.address,
    this.contactPhone,
    this.fulfilmentNote,
    this.dispatchNote,
    this.buyerNote,
    this.sellerNote,
    this.declineReason,
    this.cancelReason,
    this.cancelledBy,
    this.problemNote,
    this.problemReportedAt,
    this.revision = 0,
    this.expiresAt,
    this.expiryStage,
    this.allowedActions = const [],
    this.payment = const StoreOrderPayment(),
    this.events = const [],
    this.createdAt,
    this.updatedAt,
    this.buyerName,
    this.source,
    this.campaignTitle,
  });

  final String id;
  final String reference;

  /// "seller" or "buyer": who is looking.
  final String role;
  final StoreOrderStatus status;

  /// The server's words for where it is, for [role].
  final String statusLabel;
  final bool open;
  final String storeId;
  final String? storeName;
  final String? storeUrl;
  final String currency;
  final List<StoreOrderItem> items;

  final int requestedSubtotalMinor;
  final int? sellerSubtotalMinor;
  final int? deliveryFeeMinor;
  final int? totalMinor;

  /// The figure to show: the store's offer once it answered, the request
  /// until then.
  final int displayTotalMinor;

  /// The buyer confirmed the final details.
  final bool isFinal;

  /// "delivery" or "collection": how it is handed over now, and how the
  /// buyer first asked for it.
  final String fulfilment;
  final String requestedFulfilment;
  final String? address;
  final String? contactPhone;
  final String? fulfilmentNote;
  final String? dispatchNote;
  final String? buyerNote;
  final String? sellerNote;
  final String? declineReason;
  final String? cancelReason;
  final String? cancelledBy;
  final String? problemNote;
  final DateTime? problemReportedAt;

  /// The store's offer number: a buyer confirms this exact one.
  final int revision;
  final DateTime? expiresAt;

  /// "seller_response" or "buyer_confirmation": whose deadline [expiresAt] is.
  final String? expiryStage;
  final List<StoreOrderAction> allowedActions;
  final StoreOrderPayment payment;
  final List<StoreOrderEvent> events;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  // The store's view only.
  final String? buyerName;

  /// Where the buyer came from ("whatsapp", "tiktok"...), when known.
  final String? source;
  final String? campaignTitle;

  bool get isSeller => role == 'seller';
  bool get isDelivery => fulfilment == 'delivery';
  bool can(StoreOrderAction action) => allowedActions.contains(action);

  factory StoreOrder.fromJson(Map<String, dynamic> j) {
    final store = (j['store'] as Map?)?.cast<String, dynamic>() ?? const {};
    final totals = (j['totals'] as Map?)?.cast<String, dynamic>() ?? const {};
    final handover = (j['fulfilment'] as Map?)?.cast<String, dynamic>() ?? const {};
    final problem = (j['problem'] as Map?)?.cast<String, dynamic>();
    final buyer = (j['buyer'] as Map?)?.cast<String, dynamic>();
    final attribution = (j['attribution'] as Map?)?.cast<String, dynamic>();
    final campaign = (attribution?['campaign'] as Map?)?.cast<String, dynamic>();
    return StoreOrder(
      id: j['id'] as String? ?? '',
      reference: _text(j['reference']) ?? '',
      role: j['role'] as String? ?? 'buyer',
      status: StoreOrderStatus.parse(j['status']),
      statusLabel: _text(j['status_label']) ?? (j['status'] as String? ?? ''),
      open: j['open'] != false,
      storeId: store['id'] as String? ?? '',
      storeName: _text(store['name']),
      storeUrl: _text(store['url']),
      currency: _text(j['currency']) ?? 'KES',
      items: [
        for (final i in j['items'] as List? ?? const [])
          if (i is Map) StoreOrderItem.fromJson(i.cast<String, dynamic>()),
      ],
      requestedSubtotalMinor: _int(totals['requested_subtotal_minor']),
      sellerSubtotalMinor: _intOrNull(totals['seller_subtotal_minor']),
      deliveryFeeMinor: _intOrNull(totals['delivery_fee_minor']),
      totalMinor: _intOrNull(totals['total_minor']),
      displayTotalMinor: _int(totals['display_total_minor']),
      isFinal: totals['final'] == true,
      fulfilment: handover['method'] as String? ?? 'delivery',
      requestedFulfilment: handover['requested_method'] as String? ??
          (handover['method'] as String? ?? 'delivery'),
      address: _text(handover['address']),
      contactPhone: _text(handover['contact_phone']),
      fulfilmentNote: _text(handover['note']),
      dispatchNote: _text(handover['dispatch_note']),
      buyerNote: _text(j['buyer_note']),
      sellerNote: _text(j['seller_note']),
      declineReason: _text(j['decline_reason']),
      cancelReason: _text(j['cancel_reason']),
      cancelledBy: _text(j['cancelled_by']),
      problemNote: _text(problem?['note']),
      problemReportedAt: parseBackendUtc(problem?['reported_at'] as String?),
      revision: _int(j['revision']),
      expiresAt: parseBackendUtc(j['expires_at'] as String?),
      expiryStage: _text(j['expiry_stage']),
      allowedActions: [
        for (final a in j['allowed_actions'] as List? ?? const [])
          if (StoreOrderAction.parse(a) case final StoreOrderAction action) action,
      ],
      payment: StoreOrderPayment.fromJson(j['payment']),
      events: [
        for (final e in j['events'] as List? ?? const [])
          if (e is Map) StoreOrderEvent.fromJson(e.cast<String, dynamic>()),
      ],
      createdAt: parseBackendUtc(j['created_at'] as String?),
      updatedAt: parseBackendUtc(j['updated_at'] as String?),
      buyerName: _text(buyer?['name']),
      source: _text(attribution?['source']),
      campaignTitle: _text(campaign?['title']),
    );
  }
}

/// One row of the store's order list (GET /stores/{id}/orders).
class StoreOrderSummary {
  const StoreOrderSummary({
    required this.id,
    required this.reference,
    required this.status,
    required this.statusLabel,
    this.open = true,
    this.needsAction = false,
    this.itemCount = 0,
    this.firstItem,
    this.currency = 'KES',
    this.totalMinor = 0,
    this.isFinal = false,
    this.fulfilment = 'delivery',
    this.createdAt,
    this.updatedAt,
    this.expiresAt,
    this.buyerName,
    this.problemReported = false,
  });

  final String id;
  final String reference;
  final StoreOrderStatus status;
  final String statusLabel;
  final bool open;

  /// The store has something to do on it now.
  final bool needsAction;
  final int itemCount;
  final String? firstItem;
  final String currency;
  final int totalMinor;
  final bool isFinal;
  final String fulfilment;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? expiresAt;
  final String? buyerName;
  final bool problemReported;

  /// "Samsung A15 and 2 more".
  String get itemsLine {
    final first = firstItem ?? 'An order';
    return itemCount > 1 ? '$first and ${itemCount - 1} more' : first;
  }

  factory StoreOrderSummary.fromJson(Map<String, dynamic> j) => StoreOrderSummary(
        id: j['id'] as String? ?? '',
        reference: _text(j['reference']) ?? '',
        status: StoreOrderStatus.parse(j['status']),
        statusLabel: _text(j['status_label']) ?? (j['status'] as String? ?? ''),
        open: j['open'] != false,
        needsAction: j['needs_action'] == true,
        itemCount: _int(j['item_count']),
        firstItem: _text(j['first_item']),
        currency: _text(j['currency']) ?? 'KES',
        totalMinor: _int(j['total_minor']),
        isFinal: j['final'] == true,
        fulfilment: j['fulfilment'] as String? ?? 'delivery',
        createdAt: parseBackendUtc(j['created_at'] as String?),
        updatedAt: parseBackendUtc(j['updated_at'] as String?),
        expiresAt: parseBackendUtc(j['expires_at'] as String?),
        buyerName: _text(j['buyer_name']),
        problemReported: j['problem_reported'] == true,
      );
}

class StoreOrdersPage {
  const StoreOrdersPage({this.items = const [], this.total = 0});
  final List<StoreOrderSummary> items;
  final int total;

  factory StoreOrdersPage.fromJson(Map<String, dynamic> j) => StoreOrdersPage(
        items: [
          for (final o in j['items'] as List? ?? const [])
            if (o is Map) StoreOrderSummary.fromJson(o.cast<String, dynamic>()),
        ],
        total: _int(j['total']),
      );
}

/// The counts behind the Orders tab (GET /stores/{id}/orders/summary).
class StoreOrdersOverview {
  const StoreOrdersOverview({this.counts = const {}, this.unread = 0, this.acceptingOrders = true});

  /// Orders per group (StoreOrderGroup.value).
  final Map<String, int> counts;

  /// The owner's order updates not read yet.
  final int unread;
  final bool acceptingOrders;

  int count(StoreOrderGroup group) => counts[group.value] ?? 0;

  factory StoreOrdersOverview.fromJson(Map<String, dynamic> j) {
    final raw = (j['counts'] as Map?) ?? const {};
    return StoreOrdersOverview(
      counts: {
        for (final e in raw.entries)
          if (e.value is num) e.key.toString(): (e.value as num).toInt(),
      },
      unread: _int(j['unread']),
      acceptingOrders: j['accepting_orders'] != false,
    );
  }
}

/// A product's stock, as the owner set it
/// (PATCH /stores/{id}/manage/listings/{listing_id}/stock).
class StoreListingStock {
  const StoreListingStock({
    required this.listingId,
    this.stockTracked = false,
    this.quantity,
    this.stockReserved = 0,
    this.stockInDeals = 0,
    this.availableQuantity,
    this.temporarilyUnavailable = false,
  });

  final String listingId;
  final bool stockTracked;

  /// On hand while counted; the stated quantity otherwise.
  final int? quantity;

  /// Units accepted orders hold until they are handed over.
  final int stockReserved;

  /// Units chat deals still under way hold.
  final int stockInDeals;

  /// What an order or a chat deal may still take, counted or not.
  final int? availableQuantity;
  final bool temporarilyUnavailable;

  factory StoreListingStock.fromJson(Map<String, dynamic> j) => StoreListingStock(
        listingId: j['listing_id'] as String? ?? '',
        stockTracked: j['stock_tracked'] == true,
        quantity: _intOrNull(j['stock_on_hand'] ?? j['quantity']),
        stockReserved: _int(j['stock_reserved']),
        stockInDeals: _int(j['stock_committed_to_deals']),
        availableQuantity: _intOrNull(j['available_quantity']),
        temporarilyUnavailable: j['temporarily_unavailable'] == true,
      );
}

/// One product's changed line in a store's proposal.
class ProposedOrderItem {
  const ProposedOrderItem({required this.itemId, required this.quantity, this.unitPriceMinor});
  final String itemId;

  /// 0: the store can't supply it.
  final int quantity;

  /// Null keeps the price it has.
  final int? unitPriceMinor;

  Map<String, dynamic> toJson() => {
        'item_id': itemId,
        'quantity': quantity,
        if (unitPriceMinor != null) 'unit_price_minor': unitPriceMinor,
      };
}
