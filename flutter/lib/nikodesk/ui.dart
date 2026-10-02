import 'package:flutter/material.dart';

class NikoLanguage {
  static bool english = false;

  static void usePreference(String language) {
    english = language.isNotEmpty && !language.startsWith('zh');
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

void nikoNotice(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
      ?.showSnackBar(SnackBar(content: Text(message)));
}
