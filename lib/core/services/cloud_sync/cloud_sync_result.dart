/// 云同步操作结果
///
/// 用于承载一次云同步相关操作（连接测试、建立连接等）的执行结果，
/// 供界面层统一展示提示信息
class CloudSyncResult {
  /// 操作是否成功
  final bool success;

  /// 结果提示信息
  final String message;

  /// 本次同步是否被服务端限流（频率限制或配额耗尽）
  ///
  /// 调度器据此进入冷却期，避免撞限后按原间隔反复重试继续被拒；
  /// 与 [success] 独立：中途被限流中止的同步可能已完成部分项目，
  /// 此时 [success] 仍为 true，但剩余内容需要延后重试
  final bool rateLimited;

  const CloudSyncResult._(this.success, this.message, this.rateLimited);

  /// 成功结果
  const CloudSyncResult.success(String message, {bool rateLimited = false})
    : this._(true, message, rateLimited);

  /// 失败结果
  const CloudSyncResult.failure(String message, {bool rateLimited = false})
    : this._(false, message, rateLimited);
}
