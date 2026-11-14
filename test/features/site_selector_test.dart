import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/features/site_stats/site_selector.dart';
import 'package:flutter_test/flutter_test.dart';

SiteNodeStat _stat({
  required String node,
  double speed = 0,
  double duration = 0,
  int success = 0,
  int failure = 0,
  int download = 0,
}) {
  final now = DateTime.now();
  return SiteNodeStat(
    site: 'example.com',
    node: node,
    speedEwma: speed,
    durationEwma: duration,
    successCount: success,
    failureCount: failure,
    totalDownload: download,
    lastUsedAt: now,
  );
}

void main() {
  group('SiteSelector.score', () {
    test('ranks a fast node above a slow one', () {
      final selector = SiteSelector(noiseEnabled: false);
      final fast = _stat(
        node: 'fast',
        speed: 1024 * 1024,
        duration: 200,
        success: 10,
        download: 4096,
      );
      final slow = _stat(
        node: 'slow',
        speed: 64 * 1024,
        duration: 800,
        success: 10,
        download: 4096,
      );
      expect(selector.score(fast), greaterThan(selector.score(slow)));
    });

    test('penalizes failures', () {
      final selector = SiteSelector(noiseEnabled: false);
      final reliable = _stat(
        node: 'ok',
        speed: 256 * 1024,
        duration: 500,
        success: 10,
        download: 4096,
      );
      final flaky = _stat(
        node: 'flaky',
        speed: 256 * 1024,
        duration: 500,
        success: 5,
        failure: 5,
        download: 4096,
      );
      expect(selector.score(reliable), greaterThan(selector.score(flaky)));
    });

    test('tiny transfers rank by duration, not speed', () {
      final selector = SiteSelector(noiseEnabled: false);
      final quick = _stat(node: 'quick', duration: 100, success: 10);
      final slowSmall = _stat(node: 'slowsmall', duration: 900, success: 10);
      expect(selector.score(quick), greaterThan(selector.score(slowSmall)));
    });

    test('unsampled pairs score below everything', () {
      final selector = SiteSelector(noiseEnabled: false);
      expect(selector.score(_stat(node: 'empty')), double.negativeInfinity);
    });
  });

  group('SiteSelector.rank', () {
    test('orders candidates best first', () {
      final selector = SiteSelector(explorationRate: 0, noiseEnabled: false);
      final ranking = selector.rank('example.com', [
        _stat(node: 'b', speed: 1024 * 1024, duration: 300, success: 10),
        _stat(node: 'a', speed: 64 * 1024, duration: 900, success: 10),
      ]);
      expect(ranking.best, 'b');
      expect(ranking.candidates.map((item) => item.node).toList(), ['b', 'a']);
    });

    test('exploration promotes the runner-up deterministically at rate 1', () {
      final selector = SiteSelector(explorationRate: 1, noiseEnabled: false);
      final ranking = selector.rank('example.com', [
        _stat(node: 'best', speed: 1024 * 1024, duration: 100, success: 10),
        _stat(node: 'second', speed: 512 * 1024, duration: 200, success: 10),
      ]);
      expect(ranking.best, 'second');
    });
  });
}
