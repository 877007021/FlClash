import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class SiteStatsView extends ConsumerStatefulWidget {
  const SiteStatsView({super.key});

  @override
  ConsumerState<SiteStatsView> createState() => _SiteStatsViewState();
}

class _SiteStatsViewState extends ConsumerState<SiteStatsView> {
  List<SiteNodeStat>? _stats;
  var _clearing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final stats = await database.siteNodeStatsDao.allStats();
    if (!mounted) {
      return;
    }
    setState(() {
      _stats = stats;
    });
  }

  Future<void> _clear() async {
    if (_clearing) {
      return;
    }
    setState(() {
      _clearing = true;
    });
    try {
      await database.siteNodeStatsDao.clear();
      await _refresh();
    } finally {
      if (mounted) {
        setState(() {
          _clearing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final stats = _stats;
    return Scaffold(
      title: appLocalizations.siteStats,
      menuItems: [
        PopupMenuItem(
          label: appLocalizations.autoSiteNodeSwitch,
          onPressed: () => ref
              .read(appSettingProvider.notifier)
              .update(
                (state) => state.copyWith(
                  autoSiteNodeSwitch: !state.autoSiteNodeSwitch,
                ),
              ),
        ),
      ],
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.removeCircle,
          tooltip: appLocalizations.clearData,
          onPressed: _stats?.isNotEmpty == true && !_clearing ? _clear : null,
        ),
        IconButtonData(
          glyph: AppGlyphs.refresh,
          tooltip: appLocalizations.refresh,
          onPressed: _refresh,
        ),
      ],
      body: switch (stats) {
        null => const SizedBox.shrink(),
        [] => Center(child: Text(appLocalizations.siteStatsEmpty)),
        _ => PrismListView(
          itemCount: stats.length,
          itemBuilder: (context, index) {
            final stat = stats[index];
            final total = stat.successCount + stat.failureCount;
            return ListItem(
              title: Text(stat.site),
              subtitle: Text(
                '${stat.node} · '
                '${stat.totalDownload.traffic.show} · '
                '${stat.speedEwma.round().traffic.show}/s · '
                '${(stat.durationEwma / 1000).toStringAsFixed(1)}s · '
                '$total',
              ),
            );
          },
        ),
      },
    );
  }
}
