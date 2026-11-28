import 'dart:async';

import 'package:flutter/foundation.dart';

/// 云同步调度器
///
/// 负责挑选自动同步的执行时机，真正的同步动作由上层通过 [onTrigger] 提供：
/// - 本地内容变化后按同步间隔模式触发：实时模式下几乎立即同步，定时模式下静置一段时间
/// - 按设定的时间间隔周期性触发（实时模式不使用周期定时器）
/// - 服务端限流（坚果云等按请求计费的网盘）后进入冷却期，冷却期内不再发起任何自动同步
///
/// 该类只关心「什么时候同步」，不关心「怎么同步」，
/// 是否满足同步条件由上层在 [onTrigger] 中判断
class SyncScheduler {
  SyncScheduler({
    required Future<void> Function() onTrigger,
    this.onCooldownChanged,
  }) : _onTrigger = onTrigger;

  /// 定时模式下，本地内容变化后需要静置的时长
  ///
  /// 编辑过程中会持续保存，等待内容稳定后再同步可以避免无谓的传输
  static const Duration debounceDuration = Duration(seconds: 60);

  /// 实时模式下，本地内容变化后需要静置的时长
  ///
  /// 保存动作本身已经是防抖后的结果（停止输入才会保存），
  /// 这里只留极短的合并窗口，用于吸收连续触发的多次保存
  static const Duration realtimeDebounceDuration = Duration(seconds: 1);

  /// 限流后的冷却时长阶梯
  ///
  /// 连续被判限流时逐级拉长，直到上限；一次成功同步后立即归零。
  /// 坚果云对请求频率有硬性限制，撞限后立刻重试只会继续被拒，
  /// 冷却期让服务端的计数窗口自然衰减
  static const List<Duration> throttleSteps = [
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 3),
    Duration(minutes: 5),
    Duration(minutes: 10),
  ];

  /// 触发同步的动作
  final Future<void> Function() _onTrigger;

  /// 冷却状态变化时的通知
  ///
  /// 界面据此刷新「限流暂停」提示，冷却结束时也能及时恢复常规状态
  final void Function()? onCooldownChanged;

  /// 内容变化的防抖定时器
  Timer? _debounceTimer;

  /// 周期性同步定时器
  Timer? _intervalTimer;

  /// 限流冷却结束的定时器
  Timer? _cooldownTimer;

  /// 是否处于实时同步模式
  bool _realtime = false;

  /// 当前生效的周期
  Duration? _interval;

  /// 连续触发限流的次数，用于选择冷却时长
  int _throttleCount = 0;

  /// 冷却结束的时间点，为空表示未处于冷却期
  DateTime? _cooldownUntil;

  /// 冷却期内是否被丢弃过同步请求
  bool _skippedDuringCooldown = false;

  /// 冷却剩余时长，未处于冷却期时返回 null
  Duration? get cooldownRemaining {
    final until = _cooldownUntil;
    if (until == null) return null;
    final left = until.difference(DateTime.now());
    return left.isNegative ? null : left;
  }

  /// 当前连续限流次数
  int get throttleCount => _throttleCount;

  /// 通知本地内容发生了变化
  ///
  /// 每次调用都会重新计时：实时模式下等待 [realtimeDebounceDuration] 后同步，
  /// 定时模式下等待 [debounceDuration]，只有内容停止变化达到设定时长后才会触发
  void notifyLocalChange() {
    // 冷却期内没必要等待防抖，等冷却结束后统一补一次即可
    if (_isCoolingDown) {
      _skippedDuringCooldown = true;
      debugPrint('同步冷却中，本次保存留待冷却结束后推送');
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(
      _realtime ? realtimeDebounceDuration : debounceDuration,
      () => _trigger(_realtime ? '保存后实时同步' : '本地内容变化'),
    );
  }

  /// 设置周期性同步的间隔
  ///
  /// [interval] 为 null 或 [realtime] 为 true 时不启动周期定时器：
  /// 实时同步完全由保存动作驱动，再叠加周期同步只会重复消耗请求配额
  void applyInterval(Duration? interval, {bool realtime = false}) {
    _realtime = realtime;
    _interval = interval;
    _restartInterval();

    // 输出周期同步的当前状态
    if (realtime) {
      debugPrint('自动同步已切换为实时模式，每次保存后立即同步');
    } else {
      debugPrint(
        interval == null
            ? '自动同步计时器未启动'
            : '自动同步计时器已启动，间隔 ${interval.inMinutes} 分钟',
      );
    }
  }

  /// 记录一次因服务端限流而中止的同步
  ///
  /// 按 [throttleSteps] 逐级拉长冷却时长，冷却期内丢弃所有自动触发；
  /// 冷却结束若期间有被丢弃的同步请求，立即补一次
  void recordThrottled() {
    final next = _throttleCount + 1;
    _throttleCount = next > throttleSteps.length ? throttleSteps.length : next;
    final wait = throttleSteps[_throttleCount - 1];

    // 冷却期内周期定时器停摆，避免空跑一轮就被服务端拒绝
    _intervalTimer?.cancel();
    _intervalTimer = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;

    _cooldownUntil = DateTime.now().add(wait);
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer(wait, _endCooldown);
    onCooldownChanged?.call();

    debugPrint('云端限流，自动同步冷却 ${_formatDuration(wait)}（连续第 $_throttleCount 次）');
  }

  /// 记录一次未被限流的同步
  ///
  /// 成功或与限流无关的失败都应结束冷却状态：服务端已恢复响应能力，
  /// 继续拉长间隔只会让本地改动迟迟推不上去
  void recordSuccess() {
    if (_throttleCount == 0 && _cooldownUntil == null) return;
    _throttleCount = 0;
    if (_cooldownUntil != null) {
      debugPrint('云端恢复响应，结束限流冷却');
      _endCooldown();
    }
  }

  /// 停止全部调度并清除待触发的任务
  void stop() {
    final hadTimer =
        _debounceTimer != null ||
        _intervalTimer != null ||
        _cooldownTimer != null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _intervalTimer?.cancel();
    _intervalTimer = null;
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    _cooldownUntil = null;
    _skippedDuringCooldown = false;

    // 输出周期同步的当前状态
    if (hadTimer) debugPrint('自动同步计时器已停止');
  }

  /// 是否处于限流冷却期
  bool get _isCoolingDown {
    final until = _cooldownUntil;
    if (until == null) return false;
    if (DateTime.now().isBefore(until)) return true;
    _endCooldown();
    return false;
  }

  /// 结束冷却并恢复周期定时器
  void _endCooldown() {
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    _cooldownUntil = null;
    _restartInterval();
    onCooldownChanged?.call();

    if (!_skippedDuringCooldown) return;
    _skippedDuringCooldown = false;
    _trigger('限流冷却结束补同步');
  }

  /// 按当前配置重启周期定时器
  void _restartInterval() {
    _intervalTimer?.cancel();
    final interval = _interval;
    _intervalTimer = (_realtime || interval == null || _cooldownUntil != null)
        ? null
        : Timer.periodic(interval, (_) => _trigger('到达同步间隔'));
  }

  /// 触发一次同步
  ///
  /// [source] 触发本次同步的来源描述，便于区分不同的触发通路
  /// 触发动作由同步流程内部消化异常，这里仅做兜底，避免异常逃逸到定时器
  void _trigger(String source) {
    if (_isCoolingDown) {
      _skippedDuringCooldown = true;
      debugPrint('自动同步处于限流冷却期，忽略触发（$source）');
      return;
    }
    debugPrint('自动同步触发（$source）');
    _onTrigger().catchError((Object error) {
      debugPrint('同步触发失败: $error');
    });
  }

  /// 格式化时长用于日志
  static String _formatDuration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds} 秒';
    return '${d.inMinutes} 分钟';
  }
}
