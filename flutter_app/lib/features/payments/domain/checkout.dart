// BROKA - paying BROKA for something: the listing fee, a premium plan.
//
// The screens that sell those (ListingFeeScreen, PremiumScreen) decide WHAT
// is being bought; paying for it is the same steps for both, so it lives
// here once: pick how to pay (PaymentMethodScreen), then pay that way
// (MpesaCheckoutScreen). Each seller screen hands over an order to show and
// the two calls that charge for it - nothing here knows what a listing fee
// or a plan is.
import '../../../core/utils/result.dart';

/// One line of what is being paid for: "3 months - KES 950".
class CheckoutLine {
  const CheckoutLine(this.label, this.amount);
  final String label;
  final int amount;
}

/// What the buyer sees they are paying for, and the total.
class CheckoutOrder {
  const CheckoutOrder({
    required this.title,
    required this.total,
    this.subject,
    this.lines = const [],
  });

  /// "Listing fee", "BROKA Pro".
  final String title;

  /// What it is for: the listing's name. Null when the title says it all.
  final String? subject;
  final List<CheckoutLine> lines;

  /// KES. The server charges its own figure, worked out the same way.
  final int total;
}

/// How someone can pay. M-Pesa only for now; a method added here appears
/// on the methods screen.
enum PaymentMethod { mpesa }

/// A prompt the server sent to the phone.
class ChargeStarted {
  const ChargeStarted({required this.paymentId, required this.amount});
  final String paymentId;
  final int amount;
}

/// Where that prompt stands.
class ChargeProgress {
  const ChargeProgress({required this.succeeded, required this.pending, this.paidUntil});
  final bool succeeded;
  final bool pending;

  /// What the payment bought runs until then, when it has an end.
  final DateTime? paidUntil;
}

/// The two calls an M-Pesa checkout makes.
class MpesaCharge {
  const MpesaCharge({required this.start, required this.check});

  /// Sends the STK prompt to [phone]. [idempotencyKey] is the attempt's:
  /// sent again after a timeout, the server answers with the prompt it
  /// already sent instead of a second one.
  final Future<Result<ChargeStarted>> Function(String phone, String idempotencyKey) start;
  final Future<Result<ChargeProgress>> Function(String paymentId) check;
}

/// What to say once it is paid.
class CheckoutSuccess {
  const CheckoutSuccess({required this.title, required this.body});
  final String title;

  /// Given what the payment bought runs until, when it has an end.
  final String Function(DateTime? paidUntil) body;
}
