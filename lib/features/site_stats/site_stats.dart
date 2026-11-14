import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';

/// Reduces a connection host to the site key the statistics are grouped by.
///
/// Bare IPs pass through as their own key; a host keeps its registrable
/// suffix, so `a.example.com` and `b.example.com` share one entry.
String normalizeSite(String host, {required bool isIp}) {
  final value = host.trim().toLowerCase().replaceAll(RegExp(r'^\.'), '');
  if (value.isEmpty) {
    return '';
  }
  if (isIp) {
    return value;
  }
  final parts = value.split('.');
  if (parts.length <= 2) {
    return value;
  }
  // Two-label public suffixes such as co.uk or com.cn keep one more label.
  const secondLevelSuffixes = {
    'co.uk',
    'org.uk',
    'ac.uk',
    'gov.uk',
    'com.cn',
    'net.cn',
    'org.cn',
    'com.tw',
    'com.hk',
    'com.jp',
    'com.au',
    'com.br',
    'co.jp',
    'co.kr',
    'co.nz',
    'com.sg',
    'com.tr',
    'com.mx',
    'co.in',
    'com.ar',
    'com.za',
  };
  final lastTwo = parts.sublist(parts.length - 2).join('.');
  if (secondLevelSuffixes.contains(lastTwo)) {
    return parts.length >= 3
        ? parts.sublist(parts.length - 3).join('.')
        : value;
  }
  return lastTwo;
}

/// A closed connection the tracker is ready to persist.
class ClosedSiteConnection {
  const ClosedSiteConnection({
    required this.site,
    required this.node,
    required this.host,
    required this.duration,
    required this.download,
    required this.upload,
    required this.start,
  });

  final String site;
  final String node;
  final String host;
  final Duration duration;
  final int download;
  final int upload;
  final DateTime start;
}

/// Follows live connections from Core events and turns each one into a
/// [ClosedSiteConnection] once it stops appearing in the Core's snapshot.
///
/// The Core pushes a `request` event per new connection and `requestTraffic`
/// totals while it runs, but no close event: closure is detected by comparing
/// the live map against a `getConnections` snapshot on a timer.
class SiteConnectionTracker {
  final _live = <String, TrackerInfo>{};

  static const _reconcileInterval = Duration(seconds: 10);

  /// Connections still unclosed when [reset] runs, from a Core restart.
  static const _maxLiveAge = Duration(hours: 6);

  /// Emits one batch per reconcile tick that closed connections.
  final _closedController =
      StreamController<List<ClosedSiteConnection>>.broadcast();

  Timer? _reconcileTimer;
  Future<List<TrackerInfo>> Function()? _snapshotReader;

  Stream<List<ClosedSiteConnection>> get closed => _closedController.stream;

  /// Wires the snapshot reader used for closure detection. The reader comes
  /// from the Core controller, which only exists after app assembly.
  void bindSnapshotReader(Future<List<TrackerInfo>> Function() reader) {
    _snapshotReader = reader;
  }

  void onRequest(TrackerInfo info) {
    _live[info.id] = info;
  }

  void onRequestTraffic(Map<String, RequestTraffic> traffic) {
    for (final id in traffic.keys) {
      final current = _live[id];
      if (current == null) {
        continue;
      }
      final item = traffic[id]!;
      _live[id] = current.copyWith(
        upload: item.upload,
        download: item.download,
      );
    }
  }

  /// Compares the live map against the Core snapshot, moves gone connections
  /// out, and reports them. A snapshot read failure keeps the map intact so
  /// the next tick retries.
  Future<List<ClosedSiteConnection>> reconcile() async {
    final reader = _snapshotReader;
    if (reader == null || _live.isEmpty) {
      return const [];
    }
    final List<TrackerInfo> snapshot;
    try {
      snapshot = await reader();
    } catch (error) {
      commonPrint.log(
        'site stats snapshot read failed: $error',
        logLevel: LogLevel.warning,
      );
      return const [];
    }
    final liveIds = {for (final item in snapshot) item.id};
    final closedItems = <ClosedSiteConnection>[];
    for (final id in _live.keys.toList(growable: false)) {
      if (liveIds.contains(id)) {
        continue;
      }
      final info = _live.remove(id);
      if (info == null) {
        continue;
      }
      final closed = _closedFromInfo(info);
      if (closed != null) {
        closedItems.add(closed);
      }
    }
    // A Core restart empties the snapshot while the tracker still holds the
    // pre-restart connections; age those out rather than emitting them.
    if (snapshot.isEmpty && _live.isNotEmpty) {
      _live.clear();
    }
    // Very long-lived connections (websocket keepalives) would hold stale
    // traffic totals forever; drop them past the age bound.
    final now = DateTime.now();
    _live.removeWhere((_, info) => now.difference(info.start) > _maxLiveAge);
    if (closedItems.isNotEmpty) {
      _closedController.add(closedItems);
    }
    return closedItems;
  }

  ClosedSiteConnection? _closedFromInfo(TrackerInfo info) {
    final host = info.metadata.host.isNotEmpty
        ? info.metadata.host
        : info.metadata.destinationIP;
    if (host.isEmpty) {
      return null;
    }
    final isIp = info.metadata.host.isEmpty;
    final site = normalizeSite(host, isIp: isIp);
    if (site.isEmpty) {
      return null;
    }
    final node = info.chains.firstOrNull ?? '';
    final now = DateTime.now();
    return ClosedSiteConnection(
      site: site,
      node: node,
      host: host,
      duration: now.difference(info.start),
      download: info.download,
      upload: info.upload,
      start: info.start,
    );
  }

  void start() {
    _reconcileTimer ??= Timer.periodic(_reconcileInterval, (_) {
      unawaited(reconcile());
    });
  }

  void stop() {
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
  }

  void dispose() {
    stop();
    unawaited(_closedController.close());
  }
}
