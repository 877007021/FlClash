import 'dart:async';

import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/database/database.dart';

import 'site_selector.dart';

/// Re-ranks one site after its stats change and pushes the whole site→node
/// table to the core, whose dial hook steers each connection by it.
///
/// Nothing is written into the loaded config: the table lives in the core's
/// memory, and the host re-pushes it after a core restart, so a restart
/// costs one call instead of a config rebuild.
class SiteSwitcher {
  SiteSwitcher(this._core);

  final CoreController _core;

  // The table carries its own challenger share, so the epsilon probe in
  // the ranking would only flap the primary between pushes.
  final SiteSelector _selector = SiteSelector(explorationRate: 0);

  /// One switch per site per debounce window; a burst of connection closes
  /// must not flap the selection.
  static const _debounce = Duration(seconds: 30);

  final _pending = <String, Timer>{};

  /// Called after [recordClosedConnection] touched [site]'s rows.
  void siteStatsChanged(String site) {
    _pending[site]?.cancel();
    _pending[site] = Timer(_debounce, () => unawaited(refresh()));
  }

  /// Recomputes every site's best node and pushes the whole table in one
  /// call, which also covers the core-start re-push and the toggle flip.
  Future<void> refresh() async {
    _pending.clear();
    final stats = await database.siteNodeStatsDao.allStats();
    if (stats.isEmpty) {
      return;
    }
    final bySite = <String, List<SiteNodeStat>>{};
    for (final stat in stats) {
      bySite.putIfAbsent(stat.site, () => []).add(stat);
    }
    final overrides = <String, String>{};
    for (final MapEntry(key: site, value: rows) in bySite.entries) {
      final ranking = _selector.rank(site, rows);
      final best = ranking.best;
      // A single-candidate site has nothing to choose between; leaving it
      // out keeps the table to the pairs the learning actually steers.
      if (best == null || best.isEmpty || ranking.candidates.length < 2) {
        continue;
      }
      // The runner-up rides along after a '|': the core keeps ~1/5 of the
      // site's connections on it, so a primary that turned slow or dead is
      // demoted by fresh samples instead of holding the site.
      final challenger = ranking.candidates[1].node;
      overrides[site] = challenger.isEmpty ? best : '$best|$challenger';
    }
    try {
      await _core.setSiteOverrides(overrides);
    } catch (_) {
      // The core may be restarting; the connect listener pushes again.
    }
  }

  void reset() {
    for (final timer in _pending.values) {
      timer.cancel();
    }
    _pending.clear();
  }

  void dispose() {
    reset();
  }
}
