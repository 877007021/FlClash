part of 'database.dart';

@DataClassName('SiteNodeStat')
class SiteNodeStats extends Table {
  @override
  String get tableName => 'site_node_stats';

  /// Normalized host, e.g. `example.com` without a leading dot or scheme.
  TextColumn get site => text()();

  /// Exit node or nested group name, the first chain element.
  TextColumn get node => text()();

  /// Exponentially weighted mean of per-connection throughput, bytes per
  /// second.
  RealColumn get speedEwma => real().withDefault(const Constant(0))();

  /// Exponentially weighted mean of connection duration, milliseconds.
  RealColumn get durationEwma => real().withDefault(const Constant(0))();

  /// Connections that finished with traffic flowing, the sample count the
  /// EWMA values above are computed over.
  IntColumn get successCount => integer().withDefault(const Constant(0))();

  /// Connections that closed with zero bytes downloaded.
  IntColumn get failureCount => integer().withDefault(const Constant(0))();

  /// Total bytes downloaded through this pair, for ranking and display.
  IntColumn get totalDownload => integer().withDefault(const Constant(0))();

  /// Last time a connection for this pair closed.
  DateTimeColumn get lastUsedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {site, node};
}

@DataClassName('SiteConnectionLog')
class SiteConnectionLogs extends Table {
  @override
  String get tableName => 'site_connection_logs';

  IntColumn get id => integer().autoIncrement()();

  TextColumn get site => text()();

  TextColumn get node => text()();

  /// Raw host the connection carried, kept apart from the normalized site.
  TextColumn get host => text()();

  IntColumn get durationMillis => integer()();

  IntColumn get download => integer()();

  IntColumn get upload => integer()();

  IntColumn get startMillis => integer()();

  DateTimeColumn get closedAt => dateTime()();
}

@DriftAccessor(tables: [SiteNodeStats, SiteConnectionLogs])
class SiteNodeStatsDao extends DatabaseAccessor<Database>
    with _$SiteNodeStatsDaoMixin {
  SiteNodeStatsDao(super.attachedDatabase);

  /// The EWMA half-life for per-site samples.
  static const ewmaHalfLife = Duration(minutes: 30);

  static const _maxLogs = 2000;

  Future<SiteNodeStat?> statFor(String site, String node) {
    return (select(siteNodeStats)
          ..where((t) => t.site.equals(site) & t.node.equals(node)))
        .getSingleOrNull();
  }

  Future<List<SiteNodeStat>> statsForSite(String site) {
    return (select(siteNodeStats)
          ..where((t) => t.site.equals(site))
          ..orderBy([(t) => OrderingTerm.desc(t.totalDownload)]))
        .get();
  }

  Future<List<SiteNodeStat>> allStats() {
    return (select(
      siteNodeStats,
    )..orderBy([(t) => OrderingTerm.desc(t.lastUsedAt)])).get();
  }

  Future<void> clear() {
    return transaction(() async {
      await delete(siteNodeStats).go();
      await delete(siteConnectionLogs).go();
    });
  }

  /// Ages the EWMA values by the time since the last sample, so a pair not
  /// used for days fades toward neutral instead of keeping stale glory.
  double _agedEwma(
    double value,
    DateTime lastUsedAt, {
    required int halfMillis,
  }) {
    final ageMillis = DateTime.now().difference(lastUsedAt).inMilliseconds;
    if (ageMillis <= 0) {
      return value;
    }
    final factor = math.pow(0.5, ageMillis / halfMillis).toDouble();
    return value * factor;
  }

  Future<void> recordClosedConnection({
    required String site,
    required String node,
    required String host,
    required Duration duration,
    required int download,
    required int upload,
    required DateTime start,
  }) {
    return transaction(() async {
      final existing = await statFor(site, node);
      final now = DateTime.now();
      final speed = duration.inMilliseconds > 0
          ? download / (duration.inMilliseconds / 1000)
          : 0.0;
      if (existing == null) {
        await into(siteNodeStats).insert(
          SiteNodeStatsCompanion.insert(
            site: site,
            node: node,
            speedEwma: Value(speed),
            durationEwma: Value(duration.inMilliseconds.toDouble()),
            successCount: Value(download > 0 ? 1 : 0),
            failureCount: Value(download > 0 ? 0 : 1),
            totalDownload: Value(download),
            lastUsedAt: now,
          ),
        );
      } else {
        const alpha = 0.3;
        final agedSpeed = _agedEwma(
          existing.speedEwma,
          existing.lastUsedAt,
          halfMillis: ewmaHalfLife.inMilliseconds,
        );
        final agedDuration = _agedEwma(
          existing.durationEwma,
          existing.lastUsedAt,
          halfMillis: ewmaHalfLife.inMilliseconds,
        );
        await (update(
          siteNodeStats,
        )..where((t) => t.site.equals(site) & t.node.equals(node))).write(
          SiteNodeStatsCompanion(
            speedEwma: Value(agedSpeed * (1 - alpha) + speed * alpha),
            durationEwma: Value(
              agedDuration * (1 - alpha) + duration.inMilliseconds * alpha,
            ),
            successCount: Value(existing.successCount + (download > 0 ? 1 : 0)),
            failureCount: Value(existing.failureCount + (download > 0 ? 0 : 1)),
            totalDownload: Value(existing.totalDownload + download),
            lastUsedAt: Value(now),
          ),
        );
      }
      await into(siteConnectionLogs).insert(
        SiteConnectionLogsCompanion.insert(
          site: site,
          node: node,
          host: host,
          durationMillis: duration.inMilliseconds,
          download: download,
          upload: upload,
          startMillis: start.millisecondsSinceEpoch,
          closedAt: now,
        ),
      );
      // Keep the log table bounded without a user-facing retention setting.
      final countExp = countAll();
      final countQuery = selectOnly(siteConnectionLogs)..addColumns([countExp]);
      final count = await countQuery.getSingle().then(
        (row) => row.read(countExp) ?? 0,
      );
      if (count > _maxLogs) {
        await (delete(siteConnectionLogs)..where(
              (t) => t.closedAt.isSmallerThanValue(
                now.subtract(const Duration(days: 7)),
              ),
            ))
            .go();
      }
    });
  }
}
