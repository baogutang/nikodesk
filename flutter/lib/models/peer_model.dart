import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'platform_model.dart';
import '../nikodesk/peer_event_scope.dart';
import '../nikodesk/server_scope.dart';
// ignore: depend_on_referenced_packages
import 'package:collection/collection.dart';

class Peer {
  final String id;
  // Origin of local Niko peer metadata, never restored from cloud/cache JSON.
  final String? serverNamespace;
  String hash; // personal ab hash password
  String password; // shared ab password
  String username; // pc username
  String hostname;
  String platform;
  String alias;
  List<dynamic> tags;
  bool forceAlwaysRelay = false;
  String rdpPort;
  String rdpUsername;
  bool online = false;
  String loginName; //login username
  String device_group_name;
  String note;
  bool? sameServer;

  String getId() {
    if (alias != '') {
      return alias;
    }
    return id;
  }

  Peer.fromJson(Map<String, dynamic> json, {String? serverNamespace})
      : serverNamespace = NikoServerScope.validate(serverNamespace),
        id = json['id'] ?? '',
        hash = json['hash'] ?? '',
        password = json['password'] ?? '',
        username = json['username'] ?? '',
        hostname = json['hostname'] ?? '',
        platform = json['platform'] ?? '',
        alias = json['alias'] ?? '',
        tags = json['tags'] ?? [],
        forceAlwaysRelay = json['forceAlwaysRelay'] == 'true',
        rdpPort = json['rdpPort'] ?? '',
        rdpUsername = json['rdpUsername'] ?? '',
        loginName = json['loginName'] ?? '',
        device_group_name = json['device_group_name'] ?? '',
        note = json['note'] is String ? json['note'] : '',
        sameServer = json['same_server'];

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      "id": id,
      "hash": hash,
      "password": password,
      "username": username,
      "hostname": hostname,
      "platform": platform,
      "alias": alias,
      "tags": tags,
      "forceAlwaysRelay": forceAlwaysRelay.toString(),
      "rdpPort": rdpPort,
      "rdpUsername": rdpUsername,
      'loginName': loginName,
      'device_group_name': device_group_name,
      'note': note,
      'same_server': sameServer,
    };
  }

  Map<String, dynamic> toCustomJson({required bool includingHash}) {
    var res = <String, dynamic>{
      "id": id,
      "username": username,
      "hostname": hostname,
      "platform": platform,
      "alias": alias,
      "tags": tags,
    };
    if (includingHash) {
      res['hash'] = hash;
    }
    return res;
  }

  Map<String, dynamic> toGroupCacheJson() {
    return <String, dynamic>{
      "id": id,
      "username": username,
      "hostname": hostname,
      "platform": platform,
      "login_name": loginName,
      "device_group_name": device_group_name,
    };
  }

  Peer({
    required this.id,
    required this.hash,
    required this.password,
    required this.username,
    required this.hostname,
    required this.platform,
    required this.alias,
    required this.tags,
    required this.forceAlwaysRelay,
    required this.rdpPort,
    required this.rdpUsername,
    required this.loginName,
    required this.device_group_name,
    required this.note,
    this.sameServer,
    this.serverNamespace,
  });

  Peer.loading()
      : this(
          id: '...',
          hash: '',
          password: '',
          username: '...',
          hostname: '...',
          platform: '...',
          alias: '',
          tags: [],
          forceAlwaysRelay: false,
          rdpPort: '',
          rdpUsername: '',
          loginName: '',
          device_group_name: '',
          note: '',
        );
  bool equal(Peer other) {
    return id == other.id &&
        serverNamespace == other.serverNamespace &&
        hash == other.hash &&
        password == other.password &&
        username == other.username &&
        hostname == other.hostname &&
        platform == other.platform &&
        alias == other.alias &&
        tags.equals(other.tags) &&
        forceAlwaysRelay == other.forceAlwaysRelay &&
        rdpPort == other.rdpPort &&
        rdpUsername == other.rdpUsername &&
        device_group_name == other.device_group_name &&
        loginName == other.loginName &&
        note == other.note;
  }

  factory Peer.copy(Peer other) {
    final peer = Peer(
        id: other.id,
        hash: other.hash,
        password: other.password,
        username: other.username,
        hostname: other.hostname,
        platform: other.platform,
        alias: other.alias,
        tags: other.tags.toList(),
        forceAlwaysRelay: other.forceAlwaysRelay,
        rdpPort: other.rdpPort,
        rdpUsername: other.rdpUsername,
        loginName: other.loginName,
        device_group_name: other.device_group_name,
        note: other.note,
        sameServer: other.sameServer,
        serverNamespace: other.serverNamespace);
    peer.online = other.online;
    return peer;
  }
}

enum UpdateEvent { online, load }

typedef GetInitPeers = RxList<Peer> Function();

class Peers extends ChangeNotifier {
  final String name;
  final String loadEvent;
  List<Peer> peers = List.empty(growable: true);
  // Part of the peers that are not in the rest peers list.
  // When there're too many peers, we may want to load the front 100 peers first,
  // so we can see peers in UI quickly. `restPeerIds` is the rest peers' ids.
  // And then load all peers later.
  List<String> restPeerIds = List.empty(growable: true);
  final GetInitPeers? getInitPeers;
  UpdateEvent event = UpdateEvent.load;
  static const _cbQueryOnlines = 'callback_query_onlines';
  bool nikoHasLoaded = false;
  NikoPeerLoadFailure? nikoLoadFailure;
  String? _nikoNamespace;
  bool _nikoDisposed = false;
  bool get nikoScopedLocal =>
      const bool.fromEnvironment('NIKODESK') &&
      getInitPeers == null &&
      (loadEvent == 'load_recent_peers' || loadEvent == 'load_fav_peers');

  Peers(
      {required this.name,
      required this.getInitPeers,
      required this.loadEvent}) {
    peers = getInitPeers?.call() ?? [];
    if (nikoScopedLocal) {
      _nikoNamespace = NikoServerScope.current;
      NikoServerScope.changes.addListener(_nikoScopeChanged);
    }
    platformFFI.registerEventHandler(_cbQueryOnlines, name, (evt) async {
      _updateOnlineState(evt);
    });
    platformFFI.registerEventHandler(loadEvent, name, (evt) async {
      _updatePeers(evt);
    });
  }

  @override
  void dispose() {
    _nikoDisposed = true;
    if (nikoScopedLocal) {
      NikoServerScope.changes.removeListener(_nikoScopeChanged);
    }
    platformFFI.unregisterEventHandler(_cbQueryOnlines, name);
    platformFFI.unregisterEventHandler(loadEvent, name);
    super.dispose();
  }

  void _nikoScopeChanged() {
    final next = NikoServerScope.current;
    if (next == _nikoNamespace) return;
    _nikoNamespace = next;
    peers = [];
    restPeerIds = [];
    nikoHasLoaded = false;
    nikoLoadFailure = null;
    event = UpdateEvent.load;
    notifyListeners();
  }

  void reportNikoLoadFailure(String? expectedNamespace) {
    if (_nikoDisposed ||
        !nikoScopedLocal ||
        expectedNamespace == null ||
        expectedNamespace != NikoServerScope.current) return;
    nikoLoadFailure = NikoPeerLoadFailure.readFailed;
    event = UpdateEvent.load;
    notifyListeners();
  }

  Peer getByIndex(int index) {
    if (index < peers.length) {
      return peers[index];
    } else {
      return Peer.loading();
    }
  }

  int getPeersCount() {
    return peers.length;
  }

  void _updateOnlineState(Map<String, dynamic> evt) {
    if (nikoScopedLocal) {
      if (_nikoDisposed) return;
      final scoped = nikoScopedOnlineEvent(evt, NikoServerScope.current);
      if (scoped == null || scoped.namespace != _nikoNamespace) return;
      var changed = false;
      for (final peer in peers) {
        if (peer.serverNamespace != scoped.namespace) continue;
        final bool? next = scoped.onlines.contains(peer.id)
            ? true
            : scoped.offlines.contains(peer.id)
                ? false
                : null;
        if (next != null && next != peer.online) {
          peer.online = next;
          changed = true;
        }
      }
      if (changed) {
        event = UpdateEvent.online;
        notifyListeners();
      }
      return;
    }
    int changedCount = 0;
    evt['onlines'].split(',').forEach((online) {
      for (var i = 0; i < peers.length; i++) {
        if (peers[i].id == online) {
          if (!peers[i].online) {
            changedCount += 1;
            peers[i].online = true;
          }
        }
      }
    });

    evt['offlines'].split(',').forEach((offline) {
      for (var i = 0; i < peers.length; i++) {
        if (peers[i].id == offline) {
          if (peers[i].online) {
            changedCount += 1;
            peers[i].online = false;
          }
        }
      }
    });

    if (changedCount > 0) {
      event = UpdateEvent.online;
      notifyListeners();
    }
  }

  void _updatePeers(Map<String, dynamic> evt) {
    if (nikoScopedLocal && _nikoDisposed) return;
    final onlineStates = _getOnlineStates();
    if (nikoScopedLocal) {
      final result = nikoClassifyPeerEvent(evt, NikoServerScope.current);
      if (result == null) return;
      if (result.failure != null) {
        nikoLoadFailure = result.failure;
        event = UpdateEvent.load;
        notifyListeners();
        return;
      }
      final scoped = result.ready!;
      peers = scoped.peers
          .map((peer) => Peer.fromJson(peer, serverNamespace: scoped.namespace))
          .toList();
      nikoHasLoaded = true;
      nikoLoadFailure = null;
    } else if (getInitPeers != null) {
      peers = getInitPeers?.call() ?? [];
    } else {
      peers = _decodePeers(evt['peers']);
    }

    restPeerIds = [];
    if (evt['ids'] != null) {
      restPeerIds = (evt['ids'] as String).split(',');
    }

    for (var peer in peers) {
      final state = onlineStates[peer.id];
      peer.online = state != null && state != false;
    }
    event = UpdateEvent.load;
    notifyListeners();
  }

  Map<String, bool> _getOnlineStates() {
    var onlineStates = <String, bool>{};
    for (var peer in peers) {
      onlineStates[peer.id] = peer.online;
    }
    return onlineStates;
  }

  List<Peer> _decodePeers(String peersStr) {
    try {
      if (peersStr == "") return [];
      List<dynamic> peers = json.decode(peersStr);
      return peers.map((peer) {
        return Peer.fromJson(peer as Map<String, dynamic>);
      }).toList();
    } catch (e) {
      debugPrint('peers(): $e');
    }
    return [];
  }
}
