import 'dart:math' as math;

import 'package:fl_clash/database/database.dart';

/// One draw of a standard normal, Box-Muller; the seed lives with the
/// selector so successive ranks decorrelate.
final _gaussian = math.Random();

/// One site's ranking over the nodes it has actually used.
class SiteRanking {
  const SiteRanking._({required this.site, required this.candidates});

  final String site;

  /// Nodes ordered best first, already exploration-perturbed.
  final List<SiteNodeStat> candidates;

  bool get isEmpty => candidates.isEmpty;

  String? get best => candidates.firstOrNull?.node;
}

/// Picks a node per site from the [SiteNodeStat] history the tracker keeps.
///
/// The score blends the smoothed throughput and duration with a failure
/// penalty; samples from a pair used long ago were already aged at write
/// time, so a plain ratio is enough here. An epsilon share of calls picks
/// the runner-up instead, so a node that recovered late still gets traffic
/// and the ranking can heal.
class SiteSelector {
  SiteSelector({this.explorationRate = 0.1, this.noiseEnabled = true});

  /// Share of switches that try the second-best node. Unused once
  /// [noiseEnabled] carries the exploration, kept for the ranking API.
  final double explorationRate;

  /// Off, the score is the plain decayed reward - used where the caller
  /// needs a stable order (the override table's own test assertions).
  final bool noiseEnabled;

  final _random = math.Random();

  /// Minimum samples before a pair's speed number is trusted over its
  /// duration.
  static const _trustedSamples = 3;

  /// How fast an unrefreshed pair's score fades on reads. Matches the
  /// writer's EWMA half-life, so one idle half-life costs half the score.
  static const _readHalfLife = Duration(minutes: 30);

  /// Width of the uncertainty draw, in score units. One standard deviation
  /// is this divided by the square root of the effective sample count, so a
  /// rarely used pair gets optimistic draws that earn it the challenger
  /// seat, and a well-sampled pair's draw is a rounding error.
  static const _scoreScale = 384.0;

  /// Throughput in bytes per second the pair must beat for a high failure
  /// rate to matter; tiny transfers rank by duration instead.
  static const _throughputFloor = 64 * 1024;

  double score(SiteNodeStat stat) {
    final samples = stat.successCount + stat.failureCount;
    if (samples == 0) {
      return double.negativeInfinity;
    }
    final failureRate = stat.failureCount / samples;
    final trusted =
        stat.successCount >= _trustedSamples &&
        stat.speedEwma >= _throughputFloor;
    var speed = trusted ? stat.speedEwma : 0.0;
    var durationScore = stat.durationEwma > 0 ? 1000 / stat.durationEwma : 0.0;
    // Read-time aging: a pair that has not carried traffic lately fades
    // toward neutral even without fresh samples, so a node that was good
    // days ago no longer outranks one earning samples right now. The same
    // half-life the writer uses, applied on every ranking pass.
    final age = DateTime.now().difference(stat.lastUsedAt);
    final decay = age > _readHalfLife
        ? 0.5 * (age.inMilliseconds / _readHalfLife.inMilliseconds)
        : 1.0;
    speed *= decay;
    durationScore *= decay;
    final reward = speed + durationScore - failureRate * 2;
    // Thompson-flavoured uncertainty: an optimistic guess drawn around the
    // reward, wide when the pair has few effective samples, gone once it
    // has seen enough. This replaces the fixed exploration rate - every
    // rank is one Thompson draw, so the runner-up position (and thus the
    // challenger share the core routes to it) goes to whichever node the
    // current uncertainty most favours.
    if (noiseEnabled) {
      final effective = (samples * decay).clamp(1.0, double.infinity);
      final uncertainty = _scoreScale / math.sqrt(effective);
      return reward + _gaussian.nextDouble() * uncertainty;
    }
    return reward;
  }

  /// Ranks one site's stats; [stats] are the rows of that site only.
  SiteRanking rank(String site, List<SiteNodeStat> stats) {
    final scored = [for (final stat in stats) (stat: stat, score: score(stat))]
      ..sort((a, b) => b.score.compareTo(a.score));
    final candidates = scored.map((item) => item.stat).toList();
    if (candidates.length > 1 && _random.nextDouble() < explorationRate) {
      // Try the runner-up: move it to the front without forgetting the best.
      final runnerUp = candidates[1];
      candidates
        ..removeAt(1)
        ..insert(0, runnerUp);
    }
    return SiteRanking._(site: site, candidates: candidates);
  }
}
