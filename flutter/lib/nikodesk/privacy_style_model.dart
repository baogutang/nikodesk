import 'dart:convert';
import 'dart:typed_data';

const nikoPrivacyStyleOption = 'nikodesk-privacy-style';
const nikoPrivacyStyleImpl = 'nikodesk_privacy_style_v1';
const nikoPrivacyImageLimit = 4 * 1024 * 1024;

enum NikoPrivacyPreset { snow, paper, rain, custom }

enum NikoPrivacyEffect { fog, light, rain, none }

class NikoPrivacyStyle {
  final NikoPrivacyPreset preset;
  final NikoPrivacyEffect effect;
  final bool motion, hint, clock;
  final int brightness, intensity;
  final Uint8List? image;
  const NikoPrivacyStyle(
      {this.preset = NikoPrivacyPreset.snow,
      this.effect = NikoPrivacyEffect.fog,
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
  static NikoPrivacyEffect effectFor(NikoPrivacyPreset preset) =>
      switch (preset) {
        NikoPrivacyPreset.snow => NikoPrivacyEffect.fog,
        NikoPrivacyPreset.paper => NikoPrivacyEffect.light,
        NikoPrivacyPreset.rain => NikoPrivacyEffect.rain,
        NikoPrivacyPreset.custom => NikoPrivacyEffect.none,
      };
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
      final preset = NikoPrivacyPreset.values.byName(json['preset'] as String);
      final style = NikoPrivacyStyle(
          preset: preset,
          effect: NikoPrivacyEffect.values.byName(json['effect'] as String),
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
