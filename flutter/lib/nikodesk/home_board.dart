import 'package:flutter/foundation.dart';

import 'device_store.dart';

enum NikoDeviceView { grid, list }

/// What the device workspace shares with the home chrome around it: the
/// directory summary the sidebar lists, and the filter, view and selection
/// the sidebar and command palette change. The device page owns the data
/// and every connection path; the board only carries state and requests.
class NikoDeviceBoard extends ChangeNotifier {
  List<DeviceEntry> _devices = const [];
  Map<String, bool> _online = const {};
  bool _canConnect = false;
  String _filter = 'all';
  NikoDeviceView _view = NikoDeviceView.grid;
  String? _selected;

  List<DeviceEntry> get devices => _devices;
  Map<String, bool> get online => _online;
  bool get canConnect => _canConnect;

  /// 'all', 'favorites', 'recent' or 'group:<name>'.
  String get filter => _filter;
  NikoDeviceView get view => _view;

  /// The device shown in the inspector, if any.
  String? get selected => _selected;

  List<DeviceEntry> get favorites =>
      _devices.where((device) => device.favorite).toList();

  /// Group names in first-seen order with their device counts.
  Map<String, int> get groups {
    final groups = <String, int>{};
    for (final device in _devices) {
      final group = device.group.trim();
      if (group.isNotEmpty) groups[group] = (groups[group] ?? 0) + 1;
    }
    return groups;
  }

  int get onlineCount => _online.values.where((online) => online).length;

  void publish(List<DeviceEntry> devices, Map<String, bool> online,
      {required bool canConnect}) {
    final changed = !_sameDevices(devices, _devices) ||
        !mapEquals(online, _online) ||
        canConnect != _canConnect;
    _devices = List.unmodifiable(devices);
    _online = Map.unmodifiable(online);
    _canConnect = canConnect;
    if (_selected != null && !_devices.any((d) => d.id == _selected)) {
      _selected = null;
    }
    if (_filter.startsWith('group:') &&
        !groups.containsKey(_filter.substring(6))) {
      _filter = 'all';
    }
    if (changed) notifyListeners();
  }

  // Entries are reloaded from disk on every refresh, so compare contents.
  static bool _sameDevices(List<DeviceEntry> a, List<DeviceEntry> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i], y = b[i];
      if (x.id != y.id ||
          x.alias != y.alias ||
          x.group != y.group ||
          x.favorite != y.favorite ||
          x.forceRelay != y.forceRelay ||
          x.lastConnectedAt != y.lastConnectedAt) return false;
    }
    return true;
  }

  set filter(String value) {
    if (value == _filter) return;
    _filter = value;
    notifyListeners();
  }

  set view(NikoDeviceView value) {
    if (value == _view) return;
    _view = value;
    notifyListeners();
  }

  void select(String? id) {
    if (id == _selected) return;
    _selected = id;
    notifyListeners();
  }

  // Requests from the chrome, answered by the device page while it is
  // mounted. Each returns false when no page is listening.
  Object? _owner;
  VoidCallback? _quickConnect;
  VoidCallback? _addDevice;
  void Function(String id, {bool fileTransfer})? _connect;
  VoidCallback? _focusSearch;

  void attach(Object owner,
      {required VoidCallback quickConnect,
      required VoidCallback addDevice,
      required void Function(String id, {bool fileTransfer}) connect,
      required VoidCallback focusSearch}) {
    _owner = owner;
    _quickConnect = quickConnect;
    _addDevice = addDevice;
    _connect = connect;
    _focusSearch = focusSearch;
  }

  /// A replacement page attaches before the old one is disposed, so only
  /// the current owner may detach.
  void detach(Object owner) {
    if (owner != _owner) return;
    _owner = null;
    _quickConnect = null;
    _addDevice = null;
    _connect = null;
    _focusSearch = null;
  }

  bool requestQuickConnect() => _call(_quickConnect);
  bool requestAddDevice() => _call(_addDevice);
  bool requestFocusSearch() => _call(_focusSearch);

  bool requestConnect(String id, {bool fileTransfer = false}) {
    final connect = _connect;
    if (connect == null) return false;
    connect(id, fileTransfer: fileTransfer);
    return true;
  }

  static bool _call(VoidCallback? callback) {
    if (callback == null) return false;
    callback();
    return true;
  }
}

/// Groups a numeric device ID in threes for reading, e.g. 418 223 905.
String nikoGroupedId(String id) {
  if (id.length <= 4 || !RegExp(r'^\d+$').hasMatch(id)) return id;
  final buffer = StringBuffer();
  for (var i = 0; i < id.length; i++) {
    if (i > 0 && (id.length - i) % 3 == 0) buffer.write(' ');
    buffer.write(id[i]);
  }
  return buffer.toString();
}
