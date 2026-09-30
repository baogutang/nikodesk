import 'package:flutter/foundation.dart';

class NikoServerScope {
  static final changes = ValueNotifier<String?>(null);
  static String? get current => changes.value;

  static String? validate(Object? value) =>
      value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value)
          ? value
          : null;

  static void activate(Object? value) => changes.value = validate(value);
}
