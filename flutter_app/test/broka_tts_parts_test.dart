import 'package:broka/services/broka_tts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the first sentence is spoken alone, so the voice starts soon', () {
    final parts = speechParts(
        'I found three phones under 20,000. The Samsung A15 is the cheapest at 14,500. '
        'Want me to ask the seller about delivery?');
    expect(parts.first, 'I found three phones under 20,000.');
    expect(parts.join(' '),
        'I found three phones under 20,000. The Samsung A15 is the cheapest at 14,500. '
        'Want me to ask the seller about delivery?');
  });

  test('a one-word opener keeps the next sentence with it', () {
    expect(speechParts('Sure! Here is what I found. More later.').first, 'Sure! Here is what I found.');
  });

  test('later sentences are grouped, not one request each', () {
    final text = List.generate(12, (i) => 'Sentence number $i is here.').join(' ');
    final parts = speechParts(text, maxChars: 120);
    expect(parts.length, lessThan(8));
    expect(parts.skip(1).every((p) => p.length <= 120), isTrue);
    expect(parts.join(' '), text);
  });

  test('text with no sentence break is one part', () {
    expect(speechParts('hello there'), ['hello there']);
  });

  // Voice mode writes Zeno's reply out as the voice speaks it
  // (spokenSoFar, 2026-10-14): the caption and the audio start together.
  group('spokenSoFar', () {
    const reply = 'hello there world';

    test('shows nothing before the voice starts and everything once it is done', () {
      expect(spokenSoFar(reply, 0), '');
      expect(spokenSoFar(reply, -0.2), '');
      expect(spokenSoFar(reply, 1), reply);
      expect(spokenSoFar(reply, 1.4), reply);
      expect(spokenSoFar('', 0.5), '');
    });

    test('shows the word being said, never half of it', () {
      // 0.1 of 17 characters lands inside "hello": the whole word shows.
      expect(spokenSoFar(reply, 0.1), 'hello');
      // 0.5 lands inside "there".
      expect(spokenSoFar(reply, 0.5), 'hello there');
    });

    test('stops at a word end whenever it is asked, and only ever grows', () {
      var shown = 0;
      for (var i = 0; i <= 100; i++) {
        final part = spokenSoFar(reply, i / 100);
        expect(reply.startsWith(part), isTrue, reason: '"$part" is not the start of the reply');
        expect(part.length, greaterThanOrEqualTo(shown));
        shown = part.length;
        // Nothing yet, everything, or the next character is the space after
        // a word.
        expect(part.isEmpty || part.length == reply.length || reply[part.length] == ' ', isTrue,
            reason: '"$part" ends inside a word');
      }
    });
  });
}
