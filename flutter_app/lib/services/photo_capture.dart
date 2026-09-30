// Taking or picking a photo, the same way everywhere BROKA asks for one.
//
// Listing photos got this right first (sell_photos_screen.dart): the camera
// runs inside BROKA (ListingCameraScreen), so Android never reclaims BROKA
// while the phone's own camera app has the screen - on the 2-3 GB phones
// most sellers carry it often did, and coming back meant a cold start with
// the photo gone. The phone's camera is only the fallback, for a phone where
// BROKA's can't start. Store images, chat photos and the damaged-goods
// report still opened the phone's camera directly, each at its own size and
// quality; they come through here now, so a photo taken anywhere in the app
// is taken and sized the way a listing photo is.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../main.dart';
import '../screens/listing_camera_screen.dart';

enum PhotoSource { camera, gallery }

class PhotoCapture {
  PhotoCapture._();

  // The phone's camera app, when BROKA's can't run: what the sell wizard's
  // fallback asks for (sell_photos_screen.dart), about the 1080p BROKA's own
  // camera takes.
  static const phoneCameraQuality = 75;
  static const phoneCameraMaxWidth = 1080.0;

  // A gallery pick, as the sell wizard's cover step takes one
  // (sell_showcase_screen.dart). The server keeps at most 1600 px; this
  // leaves room for a wide store cover without uploading a 12 MP original.
  static const galleryQuality = 85;
  static const galleryMaxSide = 2048.0;

  /// BROKA's camera, for up to [maxPhotos] photos counting [alreadyTaken].
  /// Each one is handed to [onCaptured] the moment it's taken (move it
  /// somewhere durable, start its upload, and return where it now is).
  /// Completes when the camera is closed.
  ///
  /// Where BROKA's camera can't start, the screen offers the phone's
  /// camera instead, for one photo.
  static Future<void> takePhotos(
    BuildContext context, {
    required int alreadyTaken,
    required int maxPhotos,
    required Future<File> Function(File photo) onCaptured,
    String hint = ListingCameraScreen.defaultHint,
  }) async {
    final usePhoneCamera = await Navigator.of(context).push<bool>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ListingCameraScreen(
        alreadyTaken: alreadyTaken,
        maxPhotos: maxPhotos,
        onCaptured: onCaptured,
        hint: hint,
      ),
    ));
    if (usePhoneCamera != true || !context.mounted) return;
    final photo = await _pick(context, ImageSource.camera);
    if (photo != null) await onCaptured(photo);
  }

  /// One photo from BROKA's camera, or null if none was taken. [keep], if
  /// given, moves it somewhere durable first; the result is where it went.
  static Future<File?> takePhoto(
    BuildContext context, {
    String hint = ListingCameraScreen.defaultHint,
    Future<File> Function(File photo)? keep,
  }) async {
    File? taken;
    await takePhotos(
      context,
      alreadyTaken: 0,
      maxPhotos: 1,
      hint: hint,
      onCaptured: (photo) async => taken = keep == null ? photo : await keep(photo),
    );
    return taken;
  }

  /// One photo from the gallery, or null.
  static Future<File?> pickFromGallery(BuildContext context) =>
      _pick(context, ImageSource.gallery);

  static Future<File?> _pick(BuildContext context, ImageSource source) async {
    final camera = source == ImageSource.camera;
    try {
      final x = await ImagePicker().pickImage(
        source: source,
        imageQuality: camera ? phoneCameraQuality : galleryQuality,
        maxWidth: camera ? phoneCameraMaxWidth : galleryMaxSide,
        maxHeight: camera ? null : galleryMaxSide,
      );
      return x == null ? null : File(x.path);
    } on PlatformException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
            e.code.contains('denied')
                ? 'BROKA needs permission to use your ${camera ? 'camera' : 'photos'}. '
                  'Allow it in your phone settings.'
                : "Couldn't open the ${camera ? 'camera' : 'gallery'}.")));
      }
      return null;
    }
  }

  /// "Take a photo" or "Choose from gallery", or null if dismissed.
  static Future<PhotoSource?> askSource(BuildContext context) =>
      showModalBottomSheet<PhotoSource>(
        context: context,
        backgroundColor: BrokaColors.bgMid,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
        builder: (sheet) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 8),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                  color: BrokaColors.border, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 12),
            _sourceTile(sheet, PhotoSource.camera, Icons.photo_camera_outlined,
                'Take a photo', BrokaColors.gold),
            _sourceTile(sheet, PhotoSource.gallery, Icons.photo_library_outlined,
                'Choose from gallery', BrokaColors.neonBlue),
            const SizedBox(height: 8),
          ]),
        ),
      );

  static Widget _sourceTile(BuildContext sheet, PhotoSource source, IconData icon,
          String label, Color color) =>
      ListTile(
        leading: Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: color.withOpacity(0.14),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        title: Text(label, style: const TextStyle(color: BrokaColors.textHigh)),
        onTap: () => Navigator.pop(sheet, source),
      );
}
