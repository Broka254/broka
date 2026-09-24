// Background uploads for the photos a user picks, one per file.
//
// A photo starts uploading the moment it is taken, while the user carries
// on through the rest of the form. By the time they press Publish the
// uploads are usually done, and Publish sends ids instead of image data.
// Each photo shows its own progress and, if it failed, a retry.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/network/api_client.dart';
import 'image_upload_service.dart';

enum PhotoUploadStatus { uploading, done, failed }

class PhotoUploadState {
  final PhotoUploadStatus status;
  final double progress;
  final String? assetId;
  final String? error;

  /// The stored image's URLs, when this upload finished in this session
  /// (a state restored from a draft has only the id).
  final UploadedImage? image;

  const PhotoUploadState._(this.status, this.progress, this.assetId, this.error, [this.image]);
  const PhotoUploadState.uploading(double progress)
      : this._(PhotoUploadStatus.uploading, progress, null, null);
  const PhotoUploadState.done(String assetId, {UploadedImage? image})
      : this._(PhotoUploadStatus.done, 1, assetId, null, image);
  const PhotoUploadState.failed(String error)
      : this._(PhotoUploadStatus.failed, 0, null, error);
}

/// A photo that still couldn't be uploaded when it was needed.
class PhotoUploadIncomplete implements Exception {
  final int index;
  final String reason;
  const PhotoUploadIncomplete(this.index, this.reason);
  @override
  String toString() => "Photo ${index + 1} couldn't be uploaded: $reason";
}

class PhotoUploadTracker extends ChangeNotifier {
  PhotoUploadTracker({this.purpose = ImagePurpose.listingPhoto, ImageUploadService? service})
      : _service = service;

  final String purpose;
  final ImageUploadService? _service;
  ImageUploadService get _uploader => _service ?? imageUploadService;

  final Map<String, PhotoUploadState> _states = {};
  final Map<String, Future<String?>> _inFlight = {};

  PhotoUploadState? stateFor(File file) => _states[file.path];

  /// Photo path -> asset id, for every photo that finished. Saved with the
  /// draft so a restored draft doesn't upload the same photos twice.
  Map<String, String> get uploadedIds => {
        for (final e in _states.entries)
          if (e.value.assetId != null) e.key: e.value.assetId!,
      };

  void restore(Map<String, String> pathToAssetId) {
    pathToAssetId.forEach((path, id) => _states[path] = PhotoUploadState.done(id));
  }

  /// Starts uploading [file] unless it is already uploaded or uploading.
  void start(File file) {
    final state = _states[file.path];
    if (state?.status == PhotoUploadStatus.done || _inFlight.containsKey(file.path)) return;
    _inFlight[file.path] = _run(file);
  }

  void remove(File file) {
    _states.remove(file.path);
    notifyListeners();
  }

  Future<String?> _run(File file) async {
    _states[file.path] = const PhotoUploadState.uploading(0);
    notifyListeners();
    try {
      final uploaded = await _uploader.uploadFile(file, purpose: purpose, onProgress: (p) {
        if (_states[file.path]?.status != PhotoUploadStatus.uploading) return;
        _states[file.path] = PhotoUploadState.uploading(p);
        notifyListeners();
      });
      // A photo removed while uploading stays removed.
      if (_states.containsKey(file.path)) {
        _states[file.path] = PhotoUploadState.done(uploaded.id, image: uploaded);
      }
      return uploaded.id;
    } catch (e) {
      if (_states.containsKey(file.path)) {
        _states[file.path] = PhotoUploadState.failed(
            e is ApiException ? e.message : 'Check your connection');
      }
      return null;
    } finally {
      _inFlight.remove(file.path);
      notifyListeners();
    }
  }

  /// The asset ids for [files], in order. Waits for uploads in progress
  /// and tries a failed or never-started one once more. Throws
  /// [PhotoUploadIncomplete] naming the first photo that still failed.
  Future<List<String>> idsFor(List<File> files) async {
    final ids = <String>[];
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      var id = _states[file.path]?.assetId;
      if (id == null) {
        final pending = _inFlight[file.path];
        if (pending != null) id = await pending;
      }
      if (id == null) {
        start(file);
        id = await _inFlight[file.path];
      }
      if (id == null) {
        throw PhotoUploadIncomplete(i, _states[file.path]?.error ?? 'Check your connection');
      }
      ids.add(id);
    }
    return ids;
  }
}
