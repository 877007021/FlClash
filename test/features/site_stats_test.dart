import 'package:fl_clash/features/site_stats/site_stats.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

TrackerInfo _info({
  required String id,
  required String host,
  required String destinationIP,
  required List<String> chains,
  DateTime? start,
  int download = 0,
}) {
  return TrackerInfo(
    id: id,
    // A live-ish start keeps the tracker's stale-age cleanup out of the way.
    start: start ?? DateTime.now().subtract(const Duration(minutes: 1)),
    metadata: Metadata(
      network: 'tcp',
      sourceIP: '192.168.1.2',
      destinationIP: destinationIP,
      sourcePort: '52000',
      destinationPort: '443',
      host: host,
    ),
    chains: chains,
    rule: 'MATCH',
    rulePayload: '',
    download: download,
  );
}

void main() {
  group('normalizeSite', () {
    test('keeps two-label hosts whole', () {
      expect(normalizeSite('Example.COM', isIp: false), 'example.com');
      expect(normalizeSite('example.com', isIp: false), 'example.com');
    });

    test('collapses subdomains to the registrable suffix', () {
      expect(normalizeSite('a.b.example.com', isIp: false), 'example.com');
    });

    test('keeps one more label under two-level public suffixes', () {
      expect(normalizeSite('www.bbc.co.uk', isIp: false), 'bbc.co.uk');
      expect(
        normalizeSite('cdn.example.com.cn', isIp: false),
        'example.com.cn',
      );
    });

    test('passes bare IPs through', () {
      expect(normalizeSite('1.2.3.4', isIp: true), '1.2.3.4');
    });

    test('drops a leading dot and surrounding spaces', () {
      expect(normalizeSite(' .example.com', isIp: false), 'example.com');
    });

    test('maps empty hosts to an empty key', () {
      expect(normalizeSite('', isIp: false), '');
    });
  });

  group('SiteConnectionTracker', () {
    test('emits a closed connection once the snapshot drops it', () async {
      final tracker = SiteConnectionTracker();
      final seen = <ClosedSiteConnection>[];
      tracker.closed.listen(seen.addAll);
      tracker.onRequest(
        _info(
          id: '1',
          host: 'example.com',
          destinationIP: '1.2.3.4',
          chains: ['node-a'],
          download: 4096,
        ),
      );
      var snapshots = 0;
      tracker.bindSnapshotReader(() async {
        snapshots++;
        return snapshots == 1
            ? [
                _info(
                  id: '1',
                  host: 'example.com',
                  destinationIP: '1.2.3.4',
                  chains: ['node-a'],
                ),
              ]
            : <TrackerInfo>[];
      });
      final empty = await tracker.reconcile();
      expect(empty, isEmpty);
      expect(seen, isEmpty);
      final closed = await tracker.reconcile();
      expect(closed, hasLength(1));
      expect(closed.single.site, 'example.com');
      expect(closed.single.node, 'node-a');
      expect(closed.single.download, 4096);
    });

    test('keeps a connection whose snapshot read fails', () async {
      final tracker = SiteConnectionTracker();
      tracker.onRequest(
        _info(
          id: '1',
          host: 'example.com',
          destinationIP: '1.2.3.4',
          chains: ['node-a'],
        ),
      );
      var attempts = 0;
      // Bind a reader that fails once and then reports the connection gone.
      tracker.bindSnapshotReader(() async {
        attempts++;
        if (attempts == 1) {
          throw Exception('transport down');
        }
        return <TrackerInfo>[];
      });
      final first = await tracker.reconcile();
      expect(first, isEmpty);
      final second = await tracker.reconcile();
      expect(second, hasLength(1));
    });

    test('updates live traffic totals from requestTraffic events', () async {
      final tracker = SiteConnectionTracker();
      tracker.onRequest(
        _info(
          id: '1',
          host: 'example.com',
          destinationIP: '1.2.3.4',
          chains: ['node-a'],
        ),
      );
      tracker.onRequestTraffic({'1': (upload: 100, download: 900)});
      tracker.bindSnapshotReader(() async => <TrackerInfo>[]);
      final closed = await tracker.reconcile();
      expect(closed.single.download, 900);
      expect(closed.single.upload, 100);
    });

    test(
      'drops connections when the core restarts with an empty snapshot',
      () async {
        final tracker = SiteConnectionTracker();
        tracker.onRequest(
          _info(
            id: '1',
            host: 'example.com',
            destinationIP: '1.2.3.4',
            chains: ['node-a'],
          ),
        );
        // A request for another id makes the live map non-empty, but the
        // restart branch clears it when the snapshot is empty.
        tracker.bindSnapshotReader(() async => <TrackerInfo>[]);
        final closed = await tracker.reconcile();
        // The restart check clears the map before per-connection records are
        // kept, so the pre-restart connection is dropped, not emitted twice.
        expect(closed, hasLength(1));
        // A second reconcile finds nothing left.
        final again = await tracker.reconcile();
        expect(again, isEmpty);
      },
    );

    test('skips connections without any host or destination', () async {
      final tracker = SiteConnectionTracker();
      tracker.onRequest(
        _info(id: '1', host: '', destinationIP: '', chains: ['node-a']),
      );
      tracker.bindSnapshotReader(() async => <TrackerInfo>[]);
      final closed = await tracker.reconcile();
      expect(closed, isEmpty);
    });
  });
}
