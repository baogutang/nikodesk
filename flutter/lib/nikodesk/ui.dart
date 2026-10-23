import 'package:flutter/material.dart';

import 'nightline/surfaces.dart';
import 'nightline/tokens.dart';

class NikoLanguage {
  static bool english = false;

  static void usePreference(String language) {
    english = language.isNotEmpty && !language.startsWith('zh');
  }
}

/// The colour preset, kept in the local option [option].
class NikoAppearance {
  static const option = 'niko-ui-preset';

  static void usePreference(String preset) {
    NlColors.active = preset == 'clay' ? NlPreset.clay : NlPreset.orbit;
  }
}

String nikoText(String chinese, String english) =>
    NikoLanguage.english ? english : chinese;

class NikoTokens {
  static const gap = 16.0;
  static const radius = 12.0;
  static const pagePadding = 24.0;
}

class NikoCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const NikoCard(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(NikoTokens.gap)});

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(NikoTokens.radius),
          border: Border.all(
              color: Theme.of(context).dividerColor.withOpacity(.22)),
        ),
        child: child,
      );
}

InputDecoration nikoInput(String label, {String? hint}) => InputDecoration(
      labelText: label,
      hintText: hint,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      isDense: true,
    );

/// The stock toast as the design-system capsule when the app runs on the
/// Nightline theme; false leaves it to the stock one.
bool nikoShowToast(OverlayState overlay, String message, Duration timeout) {
  if (NlColors.maybeOf(overlay.context) == null) return false;
  NlToast.showIn(overlay, message, duration: timeout);
  return true;
}

void nikoNotice(BuildContext context, String message) {
  if (NlColors.maybeOf(context) != null && NlToast.show(context, message)) {
    return;
  }
  ScaffoldMessenger.maybeOf(context)
      ?.showSnackBar(SnackBar(content: Text(message)));
}
