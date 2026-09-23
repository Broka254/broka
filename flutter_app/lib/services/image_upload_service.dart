// Image uploads: one image in, an asset id and its URLs out.
//
// Listing photos, showcase images and store images are uploaded one at a
// time to POST /media/images, which checks, re-encodes and stores them and
// returns an id. Listings and stores are then created with those ids, so
// no request ever carries a whole gallery of base64 photos again - the
// failure that used to make publishing fail outright on a weak connection.
import 'dart:io';

import '../core/network/api_client.dart';

/// What an image is for. The backend refuses an id used for the wrong
/// thing (a store logo as a listing photo).
class ImagePurpose {
  static const listingPhoto = 'listing_photo';
  static const listingShowcase = 'listing_showcase';
  static const storeLogo = 'store_logo';
  static const storeCover = 'store_cover';
  static const storePhoto = 'store_photo';
}

class UploadedImage {
  final String id;
  final String thumb;
  final String medium;
  final String large;

  const UploadedImage({
    required this.id,
    required this.thumb,
    required this.medium,
    required this.large,
  });

  factory UploadedImage.fromJson(Map<String, dynamic> j) => UploadedImage(
        id: j['id'] as String,
        thumb: j['thumb'] as String,
        medium: j['medium'] as String,
        large: j['large'] as String,
      );
}

class ImageUploadService {
  ImageUploadService({ApiClient? client}) : _client = client;

  final ApiClient? _client;
  ApiClient get _api => _client ?? apiClient;

  /// Uploads [bytes]. A network failure or server error is retried once; a
  /// refusal (4xx: not an image, too large, rate limited) is not, since
  /// sending the same thing again gets the same answer.
  Future<UploadedImage> uploadBytes(
    List<int> bytes, {
    required String purpose,
    String filename = 'photo.jpg',
    void Function(double fraction)? onProgress,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final json = await _api.uploadFile(
          '/media/images',
          bytes: bytes,
          filename: filename,
          fields: {'purpose': purpose},
          onProgress: onProgress == null
              ? null
              : (sent, total) => onProgress(total <= 0 ? 0 : sent / total),
        );
        return UploadedImage.fromJson(json as Map<String, dynamic>);
      } on ApiException catch (e) {
        if (e.statusCode < 500) rethrow;
        lastError = e;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError!;
  }

  Future<UploadedImage> uploadFile(
    File file, {
    required String purpose,
    void Function(double fraction)? onProgress,
  }) async {
    final name = file.path.split(Platform.pathSeparator).last;
    return uploadBytes(
      await file.readAsBytes(),
      purpose: purpose,
      filename: name.isEmpty ? 'photo.jpg' : name,
      onProgress: onProgress,
    );
  }
}

final imageUploadService = ImageUploadService();
