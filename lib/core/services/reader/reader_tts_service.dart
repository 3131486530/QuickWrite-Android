import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 阅读模式语音朗读服务
///
/// 只与系统 TTS 引擎打交道：准备中文语音、设置语速、朗读一段文本，
/// 并在朗读结束/出错时回调。段落遍历、自动翻页与循环策略都由阅读模式页面决定，
/// 服务不持有任何界面状态，便于页面随时停止与重入。
class ReaderTtsService {
  ReaderTtsService();

  final FlutterTts _engine = FlutterTts();

  /// 语速档位（Android 引擎 1.0 为最快，0.5 约等于正常语速）
  static const List<double> rateSteps = <double>[0.38, 0.5, 0.65];

  static const String _rateKey = 'reader_tts_rate';
  static const String _loopKey = 'reader_tts_loop_chapter';

  /// 一段朗读结束（正常读完）
  VoidCallback? onComplete;

  /// 朗读出错
  void Function(Object error)? onError;

  bool _ready = false;

  /// 设备无可用 TTS 引擎时置位，避免反复尝试
  bool _unsupported = false;
  bool _prefsLoaded = false;

  double _rate = 0.5;
  bool _loopChapter = false;

  double get rate => _rate;
  bool get loopChapter => _loopChapter;
  bool get unsupported => _unsupported;

  /// 当前语速的中文标签
  String get rateLabel {
    if (_rate <= rateSteps.first + 0.001) return '慢';
    if (_rate >= rateSteps.last - 0.001) return '快';
    return '正常';
  }

  /// 读取本地保存的语速与单章循环偏好
  Future<void> loadPreferences() async {
    if (_prefsLoaded) return;
    _prefsLoaded = true;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _rate = _nearestStep(prefs.getDouble(_rateKey) ?? 0.5);
      _loopChapter = prefs.getBool(_loopKey) ?? false;
    } catch (_) {
      // 偏好读取失败按默认值处理，不影响朗读本身
    }
  }

  /// 切换语速档位并持久化
  Future<void> cycleRate() async {
    final int index = rateSteps.indexOf(_rate);
    _rate = rateSteps[(index < 0 ? 1 : index + 1) % rateSteps.length];
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_rateKey, _rate);
    } catch (_) {}
    if (!_ready) return;
    try {
      await _engine.setSpeechRate(_rate);
    } catch (_) {}
  }

  /// 设置是否单章循环朗读并持久化
  Future<void> setLoopChapter(bool value) async {
    _loopChapter = value;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_loopKey, value);
    } catch (_) {}
  }

  /// 准备引擎：选择中文语音、应用语速、挂上回调
  ///
  /// 返回 false 表示当前设备没有可用的 TTS 引擎（或缺少中文语音）。
  Future<bool> ensureReady() async {
    if (_ready) return true;
    if (_unsupported) return false;
    await loadPreferences();
    try {
      bool languageReady = false;
      for (final String language in <String>['zh-CN', 'zh_CN', 'zh']) {
        final Object? available = await _engine.isLanguageAvailable(language);
        if (available != true && available != 1 && available != 'true') continue;
        await _engine.setLanguage(language);
        languageReady = true;
        break;
      }
      if (!languageReady) {
        // 部分引擎不报告语言可用性，仍按中文尝试一次
        await _engine.setLanguage('zh-CN');
      }
      await _engine.setSpeechRate(_rate);
      await _engine.setPitch(1.0);
      await _engine.setVolume(1.0);
      _engine.setCompletionHandler(() => onComplete?.call());
      _engine.setCancelHandler(() {});
      _engine.setErrorHandler((dynamic message) => onError?.call(message ?? '未知错误'));
      _ready = true;
      return true;
    } catch (error) {
      _unsupported = true;
      return false;
    }
  }

  /// 朗读一段文本，读完由 [onComplete] 通知
  Future<void> speak(String text) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    try {
      await _engine.speak(trimmed);
    } catch (error) {
      onError?.call(error);
    }
  }

  /// 停止朗读（同时丢弃未播完的队列）
  Future<void> stop() async {
    try {
      await _engine.stop();
    } catch (_) {}
  }

  /// 释放引擎与回调
  Future<void> dispose() async {
    onComplete = null;
    onError = null;
    await stop();
  }

  /// 取与给定语速最接近的档位
  static double _nearestStep(double value) {
    double best = rateSteps[1];
    double distance = (value - best).abs();
    for (final double step in rateSteps) {
      final double current = (value - step).abs();
      if (current < distance) {
        best = step;
        distance = current;
      }
    }
    return best;
  }
}
