import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;
import 'privacy_style_model.dart';
import 'privacy_style_events.dart';

Uint8List _encode(Map<String, Object> values) {
  final rgba = values['pixels'] as Uint8List;
  final photo = image.Image.fromBytes(
      width: values['width'] as int,
      height: values['height'] as int,
      bytes: rgba.buffer,
      bytesOffset: rgba.offsetInBytes,
      numChannels: 4,
      order: image.ChannelOrder.rgba);
  final opaque =
      image.Image(width: photo.width, height: photo.height, numChannels: 3);
  image.fill(opaque, color: image.ColorRgb8(0, 0, 0));
  image.compositeImage(opaque, photo);
  return image.encodeJpg(opaque, quality: 92);
}

Future<Uint8List> nikoNormalizePrivacyImage(Uint8List bytes) async {
  if (bytes.isEmpty || bytes.length > 12 * 1024 * 1024) {
    throw const NikoPrivacyStyleError('image_size_limit');
  }
  final png = bytes.length >= 8 &&
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71;
  final jpeg = bytes.length >= 3 &&
      bytes[0] == 255 &&
      bytes[1] == 216 &&
      bytes[2] == 255;
  final webp = bytes.length >= 12 &&
      String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP';
  if (!png && !jpeg && !webp) {
    throw const NikoPrivacyStyleError('invalid_image');
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? frame;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final w = descriptor.width, h = descriptor.height;
    if (w <= 0 || h <= 0 || w > 4096 || h > 4096 || w * h > 8000000) {
      throw const NikoPrivacyStyleError('image_dimensions_limit');
    }
    final scale = 2560 / (w > h ? w : h);
    codec = await descriptor.instantiateCodec(
        targetWidth: scale < 1 ? (w * scale).round() : w,
        targetHeight: scale < 1 ? (h * scale).round() : h);
    frame = (await codec.getNextFrame()).image;
    final rgba = await frame.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rgba == null) {
      throw const NikoPrivacyStyleError('invalid_image');
    }
    final encoded = await compute(_encode, {
      'pixels': rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes),
      'width': frame.width,
      'height': frame.height
    });
    if (encoded.length > nikoPrivacyImageLimit) {
      throw const NikoPrivacyStyleError('image_size_limit');
    }
    return encoded;
  } finally {
    frame?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}
