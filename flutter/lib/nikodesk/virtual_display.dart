/// A native snapshot; clicking a menu never changes these confirmed slots.
class NikoVirtualDisplays {
  final bool supported, allowed;
  final Set<int> active, cleanup;
  const NikoVirtualDisplays._(
      this.supported, this.allowed, this.active, this.cleanup);
  static NikoVirtualDisplays? parse(dynamic raw) {
    if (raw is! Map ||
        raw.length != 5 ||
        raw['schema'] != 1 ||
        raw['supported'] is! bool ||
        raw['allowed'] is! bool) return null;
    Set<int>? slots(dynamic value) {
      if (value is! List ||
          value.length > 4 ||
          value.any((slot) => slot is! int || slot < 1 || slot > 4)) {
        return null;
      }
      final result = value.cast<int>().toSet();
      return result.length == value.length ? result : null;
    }

    final active = slots(raw['active']), cleanup = slots(raw['cleanup']);
    if (active == null ||
        cleanup == null ||
        active.intersection(cleanup).isNotEmpty) return null;
    return NikoVirtualDisplays._(
        raw['supported'], raw['allowed'], active, cleanup);
  }
}
