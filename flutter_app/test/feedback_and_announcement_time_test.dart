// Announcement date/time wording and feedback model parsing.
//
// The presentation helpers are pure functions of the announcement and a
// fixed `now`, so they are asserted directly - no widget tree needed.
// Dates are built in local time on purpose: users read local wall-clock
// time, and the helpers convert with toLocal().
import 'package:flutter_test/flutter_test.dart';
import 'package:broka/features/communications/domain/models/announcement.dart';
import 'package:broka/features/communications/presentation/announcement_presentation.dart';
import 'package:broka/features/feedback/domain/models/feedback.dart';

Announcement _at(DateTime published, {DateTime? expires}) => Announcement(
      id: 'a1',
      title: 'Maintenance',
      body: 'Down tonight.',
      type: AnnouncementType.maintenance,
      severity: AnnouncementSeverity.high,
      publishedAt: published,
      expiresAt: expires,
    );

void main() {
  group('AnnouncementPresentation dates', () {
    test('full date and time are both present', () {
      final at = DateTime(2026, 10, 29, 16, 45);
      expect(AnnouncementPresentation.fullDate(at), contains('Oct 29, 2026'));
      expect(AnnouncementPresentation.timeOfDay(at), '4:45 PM');
      expect(AnnouncementPresentation.fullDateTime(at),
          contains('Oct 29, 2026 · 4:45 PM'));
    });

    test('relative age scales from minutes to weeks', () {
      final now = DateTime(2026, 10, 29, 17, 0);
      expect(
          AnnouncementPresentation.relativeTime(
              now.subtract(const Duration(minutes: 5)),
              now: now),
          '5m ago');
      expect(
          AnnouncementPresentation.relativeTime(
              now.subtract(const Duration(hours: 3)),
              now: now),
          '3h ago');
      expect(
          AnnouncementPresentation.relativeTime(
              now.subtract(const Duration(days: 2)),
              now: now),
          '2d ago');
    });

    test('published line carries absolute and relative together', () {
      final now = DateTime(2026, 10, 29, 17, 0);
      final line = AnnouncementPresentation.publishedLine(
          now.subtract(const Duration(hours: 2)),
          now: now);
      expect(line, contains('2026'));
      expect(line, contains('(2h ago)'));
    });

    test('expiry countdown names the day and flags the last 3 days', () {
      final now = DateTime(2026, 10, 29, 12, 0);
      final soon = _at(now, expires: now.add(const Duration(days: 2)));
      expect(AnnouncementPresentation.expiryLine(soon, now: now),
          contains('Expires in 2 days'));
      expect(AnnouncementPresentation.expiresSoon(soon, now: now), isTrue);
      final far = _at(now, expires: now.add(const Duration(days: 20)));
      expect(AnnouncementPresentation.expiresSoon(far, now: now), isFalse);
      final gone = _at(now, expires: now.subtract(const Duration(days: 1)));
      expect(AnnouncementPresentation.expiryLine(gone, now: now), isNull);
    });
  });

  group('FeedbackSubmission parsing', () {
    test('parses a complaint with an admin reply', () {
      final parsed = FeedbackSubmission.fromJson({
        'id': 'f1',
        'kind': 'complaint',
        'category': 'seller_conduct',
        'severity': 'high',
        'subject': 'Seller was abusive',
        'body': 'Insults in chat.',
        'status': 'acknowledged',
        'admin_response': 'We are looking into it.',
        'responded_at': '2026-10-29T10:00:00Z',
        'created_at': '2026-10-29T09:00:00Z',
      });
      expect(parsed, isNotNull);
      expect(parsed!.isComplaint, isTrue);
      expect(parsed.categoryLabel, 'A seller');
      expect(parsed.status, FeedbackStatus.acknowledged);
      expect(parsed.adminResponse, 'We are looking into it.');
      expect(parsed.createdAt, isNotNull);
    });

    test('rejects rows without subject or body', () {
      expect(
          FeedbackSubmission.fromJson(
              {'id': 'f1', 'subject': '', 'body': 'x'}),
          isNull);
      expect(FeedbackSubmission.fromJson({'id': 'f1'}), isNull);
    });

    test('unknown status and kind degrade safely', () {
      final parsed = FeedbackSubmission.fromJson({
        'id': 'f1',
        'kind': 'something-new',
        'subject': 'Hi',
        'body': 'There',
        'status': 'mystery',
      });
      expect(parsed!.kind, FeedbackKind.feedback);
      expect(parsed.status, FeedbackStatus.open);
    });
  });
}
