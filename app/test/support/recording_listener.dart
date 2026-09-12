import 'package:xvpn/core/auto_route.dart';
import 'package:xvpn/core/core_log.dart';
import 'package:xvpn/core/dns_monitor.dart';
import 'package:xvpn/core/mtu_probe.dart';
import 'package:xvpn/core/startup_self_check.dart';
import 'package:xvpn/core/tunnel_health.dart';
import 'package:xvpn/core/vpn_core.dart';
import 'package:xvpn/models.dart';

/// 记录内核回调，供多个测试文件共用。
///
/// 做成一个共享的测试替身而不是每个文件各写一份：`VpnCoreListener` 会随
/// 观测能力增加而增长，散落的实现每次都要同步修改，很容易漏掉一个文件。
class RecordingListener implements VpnCoreListener {
  final List<VpnStatus> statuses = <VpnStatus>[];
  final List<String> errors = <String>[];
  final List<String> logFailures = <String>[];
  final List<SplitRecord> records = <SplitRecord>[];
  final List<DnsReport> dnsReports = <DnsReport>[];
  final List<StartupSelfCheckReport> selfChecks = <StartupSelfCheckReport>[];
  final List<AutoRouteDecision> learned = <AutoRouteDecision>[];

  /// 最近一次流量回调的完整参数。
  ({
    double downBps,
    double upBps,
    int totalBytes,
    int directBytes,
    int proxiedBytes,
    int connectionCount,
    int kernelMemory,
  })?
  lastTraffic;

  List<int?> latencies = <int?>[];

  @override
  void onStatusChanged(VpnStatus status) => statuses.add(status);

  @override
  void onTraffic({
    required double downBps,
    required double upBps,
    required int totalBytes,
    int directBytes = 0,
    int proxiedBytes = 0,
    int connectionCount = 0,
    int kernelMemory = 0,
  }) {
    lastTraffic = (
      downBps: downBps,
      upBps: upBps,
      totalBytes: totalBytes,
      directBytes: directBytes,
      proxiedBytes: proxiedBytes,
      connectionCount: connectionCount,
      kernelMemory: kernelMemory,
    );
  }

  @override
  void onLatency(int? millis) => latencies.add(millis);

  @override
  void onSplitRecord(SplitRecord record) => records.add(record);

  /// 流量增量。分流记录按目标合并后，行上的流量来自这里，因此要留痕以便断言。
  final List<ConnectionTraffic> trafficUpdates = <ConnectionTraffic>[];

  @override
  void onConnectionTraffic(ConnectionTraffic traffic) =>
      trafficUpdates.add(traffic);

  @override
  void onConnectionFailure(ConnectionFailure failure) =>
      logFailures.add(failure.target);

  @override
  void onError(String message) => errors.add(message);

  @override
  void onDnsReport(DnsReport report) => dnsReports.add(report);

  @override
  void onSelfCheck(StartupSelfCheckReport report) => selfChecks.add(report);

  @override
  void onAutoRouteLearned(AutoRouteDecision decision) => learned.add(decision);

  @override
  void onAutoRouteChanged(AutoRouteTable table) {}

  /// 隧道健康结论。断线自愈的判定依据，因此要留痕以便断言。
  final List<TunnelHealth> healthReports = <TunnelHealth>[];

  @override
  void onTunnelHealth(TunnelHealth health) => healthReports.add(health);

  /// MTU 校验结论。界面据此显示「配置的 MTU 能不能用」，因此要留痕以便断言。
  final List<MtuCheck> mtuChecks = <MtuCheck>[];

  @override
  void onMtuCheck(MtuCheck check) => mtuChecks.add(check);

  /// 内核日志到达的次数。
  ///
  /// 记次数而不是内容：内容是内核写的，测试关心的是「通知有没有发出去」。
  int kernelLogNotifications = 0;

  @override
  void onKernelLog() => kernelLogNotifications++;
}
