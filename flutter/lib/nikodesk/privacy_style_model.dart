import 'dart:convert';
import 'dart:typed_data';

const nikoPrivacyStyleOption = 'nikodesk-privacy-style';
const nikoPrivacyStyleImpl = 'nikodesk_privacy_style_v1';
const nikoPrivacyImageLimit = 4 * 1024 * 1024;

/// Nightline scenes drawn by the controlled computer, and a custom picture.
enum NikoPrivacyPreset { nightline, deepfield, aurora, graphite, custom }

/// The first presets, still found in saved choices, and their replacements.
const _nikoLegacyPresets = {
  'snow': NikoPrivacyPreset.nightline,
  'paper': NikoPrivacyPreset.graphite,
  'rain': NikoPrivacyPreset.deepfield,
};

enum NikoPrivacyEffect { fog, light, rain, none }

class NikoPrivacyStyle {
  final NikoPrivacyPreset preset;
  final NikoPrivacyEffect effect;
  final bool motion, hint, clock;
  final int brightness, intensity;
  final Uint8List? image;
  const NikoPrivacyStyle(
      {this.preset = NikoPrivacyPreset.nightline,
      this.effect = NikoPrivacyEffect.none,
      this.motion = true,
      this.hint = true,
      this.clock = false,
      this.brightness = 100,
      this.intensity = 120,
      this.image});

  bool get valid =>
      brightness >= 40 &&
      brightness <= 100 &&
      intensity >= 50 &&
      intensity <= 200 &&
      (preset == NikoPrivacyPreset.custom
          ? image != null &&
              image!.isNotEmpty &&
              image!.length <= nikoPrivacyImageLimit
          : effect == effectFor(preset));

  /// Scenes animate by themselves; a custom picture is shown as it is.
  static NikoPrivacyEffect effectFor(NikoPrivacyPreset preset) =>
      NikoPrivacyEffect.none;
  NikoPrivacyStyle copyWith(
          {NikoPrivacyPreset? preset,
          NikoPrivacyEffect? effect,
          bool? motion,
          bool? hint,
          bool? clock,
          int? brightness,
          int? intensity,
          Uint8List? image}) =>
      NikoPrivacyStyle(
          preset: preset ?? this.preset,
          effect: effect ?? this.effect,
          motion: motion ?? this.motion,
          hint: hint ?? this.hint,
          clock: clock ?? this.clock,
          brightness: brightness ?? this.brightness,
          intensity: intensity ?? this.intensity,
          image: image ?? this.image);
  Map<String, dynamic> command(int requestId) => {
        'request_id': requestId,
        'preset': preset.name,
        'effect': effect.name,
        'motion': motion,
        'brightness': brightness,
        'intensity': intensity,
        'hint': hint,
        'clock': clock,
        'image_base64': preset == NikoPrivacyPreset.custom && image != null
            ? base64Encode(image!)
            : '',
      };
  String saved() => jsonEncode(command(1));
  static NikoPrivacyStyle? read(String? encoded) {
    if (encoded == null ||
        encoded.isEmpty ||
        encoded.length > nikoPrivacyImageLimit * 4 ~/ 3 + 2048) return null;
    try {
      final json = jsonDecode(encoded) as Map<String, dynamic>;
      final name = json['preset'] as String;
      final legacy = _nikoLegacyPresets[name];
      final preset = legacy ?? NikoPrivacyPreset.values.byName(name);
      final style = NikoPrivacyStyle(
          preset: preset,
          effect: legacy != null
              ? NikoPrivacyEffect.none
              : NikoPrivacyEffect.values.byName(json['effect'] as String),
          motion: json['motion'] as bool,
          brightness: json['brightness'] as int,
          intensity: json['intensity'] as int,
          hint: json['hint'] as bool,
          clock: json['clock'] as bool,
          image: preset == NikoPrivacyPreset.custom
              ? base64Decode(json['image_base64'] as String)
              : null);
      return style.valid ? style : null;
    } catch (_) {
      return null;
    }
  }
}
