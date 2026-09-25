// The AI cover image, from the sell wizard's Cover image step.
//
// POST /showcase/preview with the seller's first photo BY ID - it was
// uploaded the moment it was taken, so nothing is sent twice - and the
// look they picked. The server stores the result as the seller's own image
// and answers with its id and URLs (`result: "asset"`), so what comes back
// is a small JSON object, not the megabytes of base64 it used to be, and
// using the cover at Activate uploads nothing.
import '../core/network/api_client.dart';

class GeneratedCover {
  const GeneratedCover({required this.assetId, required this.previewUrl, required this.largeUrl});
  final String assetId;

  /// The medium size, for the wizard's preview.
  final String previewUrl;
  final String largeUrl;
}

/// A look the seller can ask for. The id is what the server's
/// showcase.THEMES knows; the prompt text never leaves the server.
class CoverTheme {
  const CoverTheme(this.id, this.name, this.tagline);
  final String id;
  final String name;
  final String tagline;
}

class ShowcaseGenerator {
  ShowcaseGenerator({ApiClient? client}) : _client = client;
  final ApiClient? _client;
  ApiClient get _api => _client ?? apiClient;

  static const themes = <CoverTheme>[
    CoverTheme('studio', 'Clean Studio', 'Bright white, online-store sharp'),
    CoverTheme('luxury', 'Luxury Night', 'Black, gold light, premium'),
    CoverTheme('wood', 'Warm Wood', 'Cosy tabletop, soft window light'),
    CoverTheme('nature', 'Fresh Outdoors', 'Daylight and green leaves'),
    CoverTheme('neon', 'Neon Tech', 'Cyan and magenta glow'),
    CoverTheme('pastel', 'Pastel Pop', 'Soft colours on a podium'),
  ];

  /// The look most sellers of this category would pick - Zeno's pick in
  /// the wizard.
  static String recommendedFor(String category) {
    switch (category) {
      case 'Electronics':
      case 'Gaming':
        return 'neon';
      case 'Automobiles':
      case 'Music & Instruments':
        return 'luxury';
      case 'Fashion':
      case 'Beauty & Personal Care':
      case 'Baby & Kids':
        return 'pastel';
      case 'Agriculture':
      case 'Land':
      case 'Property':
      case 'Sports & Fitness':
      case 'Pets & Animals':
        return 'nature';
      case 'Home & Furniture':
      case 'Food & Beverages':
      case 'Arts & Crafts':
        return 'wood';
    }
    return 'studio';
  }

  /// Generates a cover. Throws ApiException with the server's sentence
  /// (and a code: SHOWCASE_UNAVAILABLE, SHOWCASE_REJECTED, SHOWCASE_FAILED,
  /// SHOWCASE_LIMIT) when it can't.
  Future<GeneratedCover> generate({
    required String photoId,
    required String name,
    required String category,
    required String theme,
    String? condition,
    String? note,
  }) async {
    final json = await _api.post(
      '/showcase/preview',
      {
        'photo_id': photoId,
        'name': name,
        'category': category,
        'theme': theme,
        'result': 'asset',
        if (condition != null) 'condition': condition,
        if (note != null && note.trim().isNotEmpty) 'description': note.trim(),
      },
      // The server gives fal.ai up to ~90 s plus the upload and download;
      // a shorter wait here abandoned generations that were about to land.
      timeout: const Duration(seconds: 150),
    ) as Map<String, dynamic>;
    final asset = json['asset'] as Map<String, dynamic>?;
    final id = asset?['id'] as String?;
    final medium = (asset?['medium'] ?? asset?['large']) as String?;
    if (asset == null || id == null || medium == null) {
      throw const ApiException(502, 'The AI cover came back empty. Please try again.');
    }
    return GeneratedCover(
      assetId: id,
      previewUrl: medium,
      largeUrl: (asset['large'] as String?) ?? medium,
    );
  }
}
