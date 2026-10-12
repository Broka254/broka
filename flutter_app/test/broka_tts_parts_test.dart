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
}
