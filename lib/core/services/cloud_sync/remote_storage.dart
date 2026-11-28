import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:quick_write/core/services/cloud_sync/sync_models.dart';

/// 远端存储平台类型
///
/// 同步流程本身与协议无关，仅通过 [RemoteStorage] 抽象访问云端；
/// 具体协议由该枚举区分，界面据此展示不同的连接参数
enum RemoteStorageKind {
  /// WebDAV 协议的网盘（坚果云、Nextcloud 等）
  webDav('webdav', 'WebDAV'),

  /// S3 协议的对象存储（AWS S3、Cloudflare R2、MinIO 等）
  s3('s3', 'S3');

  const RemoteStorageKind(this.id, this.label);

  /// 持久化标识
  final String id;

  /// 界面显示名称
  final String label;

  /// 由持久化标识还原平台类型，无法识别时按 WebDAV 处理
  static RemoteStorageKind fromId(String? id) {
    for (final kind in values) {
      if (kind.id == id) return kind;
    }
    return webDav;
  }
}

/// 坚果云 WebDAV 服务的主机名
const String kJianguoyunHost = 'jianguoyun.com';

/// 判断服务器地址是否指向坚果云
///
/// 坚果云对每 30 分钟内的 WebDAV 请求次数有严格限制，逐章上传会迅速耗尽配额，
/// 因此只有该平台需要把章节合并为归档包上传；其他平台没有该限制，
/// 逐章上传可以避免「改一章要重传整包」的流量浪费
bool isJianguoyunHost(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  return host == kJianguoyunHost || host.endsWith('.$kJianguoyunHost');
}

/// 云同步连接配置
///
/// 同时承载 WebDAV 与 S3 两种协议的连接参数，字段按语义复用：
/// [endpoint] 在 WebDAV 下是服务器地址、在 S3 下是服务端点；
/// [account] 在 WebDAV 下是登录账号、在 S3 下是 Access Key；
/// [secret] 在 WebDAV 下是登录密码、在 S3 下是 Secret Key
class CloudConnectionConfig {
  /// 存储平台
  final RemoteStorageKind kind;

  /// 服务地址（WebDAV 服务器地址 / S3 服务端点）
  final String endpoint;

  /// 账号（WebDAV 账号 / S3 Access Key）
  final String account;

  /// 密钥（WebDAV 密码 / S3 Secret Key）
  final String secret;

  /// 远端目录（S3 下作为对象键前缀）
  final String remoteDir;

  /// S3 区域
  final String region;

  /// S3 存储桶
  final String bucket;

  /// S3 是否使用路径风格访问（MinIO 等自建服务通常需要）
  final bool pathStyle;

  /// WebDAV 是否允许 http:// 明文连接
  ///
  /// 内网自建服务（NAS、路由器挂载盘）多数没有 HTTPS，开启后才能连接；
  /// 该开关只对 WebDAV 生效
  final bool allowInsecureHttp;

  /// WebDAV 是否忽略证书错误
  ///
  /// 自建服务常用自签证书，开启后不再校验证书链
  final bool ignoreCertificateErrors;

  const CloudConnectionConfig({
    required this.kind,
    required this.endpoint,
    required this.account,
    required this.secret,
    required this.remoteDir,
    this.region = 'cn-east-1',
    this.bucket = '',
    this.pathStyle = false,
    this.allowInsecureHttp = false,
    this.ignoreCertificateErrors = false,
  });

  /// 是否把章节合并为归档包上传
  ///
  /// 仅坚果云需要：归档包用一次请求传输上百章，可成数量级地节省请求配额。
  /// 其他平台没有请求次数限制，逐章上传可以让每次同步只传输改动的章节
  bool get packsChapters =>
      kind == RemoteStorageKind.webDav && isJianguoyunHost(endpoint);

  /// 平台识别结果的可读名称，用于界面提示当前采用的传输策略
  String get platformLabel {
    if (kind == RemoteStorageKind.s3) return 'S3 对象存储';
    return isJianguoyunHost(endpoint) ? '坚果云' : '通用 WebDAV';
  }
}

/// 远端存储抽象
///
/// 同步引擎只依赖该接口，因此 WebDAV 与 S3 可以共用同一套比对、传输与冲突处理逻辑。
/// 实现方需要保证：
/// - [remotePathOf] 返回的是「可直接用于本协议请求」的完整路径
/// - [listFilesRecursive] 返回的逻辑键相对于 [remoteDir]，且跳过内部目录与临时文件
/// - 删除文件在目标不存在时视为成功，便于重试
abstract class RemoteStorage {
  /// 远端同步根目录（已规范化，无首尾斜杠）
  String get remoteDir;

  /// 将逻辑键转换为远端完整路径
  String remotePathOf(String key);

  /// 测试与远端的连通性（地址、凭据、存储桶是否可用）
  Future<void> ping();

  /// 确保远端目录存在
  ///
  /// 对象存储没有目录概念，实现方可以留空
  Future<void> ensureDirectory(String path);

  /// 清除已创建目录的缓存
  void resetDirectoryCache();

  /// 递归列出远端同步目录下的全部文件
  Future<List<RemoteSyncFile>> listFilesRecursive();

  /// 上传本地文件到远端
  Future<void> uploadFile(String localPath, String remotePath);

  /// 上传内存中的字节数据到远端
  Future<void> uploadBytes(Uint8List bytes, String remotePath);

  /// 下载远端文件到内存
  Future<Uint8List> downloadBytes(String remotePath);

  /// 下载远端文件到内存，文件不存在时返回 null
  Future<Uint8List?> downloadBytesIfExists(String remotePath);

  /// 下载远端文件到本地指定路径
  Future<void> downloadFile(String remotePath, String localPath);

  /// 列出远端指定目录下的直接文件名
  Future<List<String>> listFileNames(String remotePath);

  /// 列出远端指定目录下的文件及其内容标识
  ///
  /// 内容标识用于判断远端文件是否发生变化：元数据读取据此跳过未变化的文件，
  /// 避免按书籍数量逐次下载。默认实现拿不到 ETag，此时调用方会退回完整下载，
  /// 支持 ETag 的服务端（如 WebDAV）应覆写本方法
  Future<List<RemoteSyncFile>> listFilesWithMeta(String remotePath) async {
    final names = await listFileNames(remotePath);
    return [
      for (final name in names)
        RemoteSyncFile(key: name, etag: '', size: 0),
    ];
  }

  /// 查询逻辑键对应的远端内容标识
  ///
  /// 仅在本地已掌握该文件最新状态时返回，例如刚完成上传且服务端回了 ETag；
  /// 返回 null 表示未知，调用方不应据此做任何缓存判断
  String? contentIdOf(String key) => null;

  /// 列出远端指定目录下的子目录名
  Future<List<String>> listDirectoryNames(String remotePath);

  /// 移动远端文件
  Future<void> moveFile(String fromPath, String toPath, {bool overwrite});

  /// 删除远端文件
  Future<void> deleteFile(String remotePath);

  /// 递归删除远端目录
  Future<void> deleteDirectoryRecursive(String remotePath);

  /// 清空远端目录内的全部内容，保留目录本身
  Future<void> clearDirectory(String remotePath);

  /// 读取远端文件属性
  Future<RemoteSyncFile> fileInfo(String key);

  /// 判断远端文件是否存在
  Future<bool> exists(String key);

  /// 是否直接覆盖写入目标路径
  ///
  /// 默认先写临时文件名再移动，保证目标文件不会出现半截内容；
  /// 但一次上传要占用两个请求，对按请求次数计费的网盘（如坚果云）
  /// 代价翻倍，这类服务端可以改为直传，省下移动请求
  bool get prefersDirectUpload => false;

  /// 释放底层连接资源
  void dispose();
}

/// 判断异常是否由服务端请求频率限制引起
bool isRemoteRateLimitError(Object error) {
  if (error is! DioException) return false;
  final status = error.response?.statusCode;
  return status == 429 || status == 503;
}

/// 云端配额耗尽时服务端的说明文字
///
/// 坚果云等网盘在流量或容量超出套餐上限时返回 403，
/// 并在响应体中给出类似 "The traffic limit has been exceeded" 的说明；
/// 短时频率限制同为 503，但重试即可恢复，因此不在此列
const List<String> _quotaTexts = [
  'insufficient storage',
  'insufficient_quota',
  'quota',
  'traffic limit',
  'storage limit',
  '超过使用限制',
  '超出限制',
  '配额',
  '空间不足',
  '流量',
];

/// 判断异常是否由云端配额（流量、容量）耗尽引起
///
/// 这类失败不会因为重试而恢复，必须等配额重置或升级套餐，
/// 因此不能按临时错误反复重试，否则只会白白消耗剩余配额；
/// 频率限制（429/503）不属于配额耗尽，交给重试机制处理
bool isRemoteQuotaExceeded(Object error) {
  if (error is! DioException) return false;

  final status = error.response?.statusCode;
  if (status == 507 || status == 509) return true;
  if (status != 403) return false;

  final raw = _rawServerTextOf(error);
  if (raw == null) return false;
  final text = raw.toLowerCase();
  return _quotaTexts.any(text.contains);
}

/// 将远端通信过程中的异常转换为便于用户理解的提示文本
String describeRemoteError(Object error) {
  if (error is DioException) {
    final status = error.response?.statusCode;

    // 配额耗尽与普通权限错误同为 403，必须优先识别，否则用户会误以为账号没权限
    if (isRemoteQuotaExceeded(error)) {
      return _withServerHint(
        '云端配额已用完（流量或容量超出套餐上限），请等待配额重置或升级套餐后再同步',
        error,
      );
    }

    if (status == 400) return _withServerHint('服务器拒绝了请求，请检查服务器地址是否指向 WebDAV 根路径', error);
    if (status == 401) return _withServerHint('认证失败，请检查账号与密码', error);
    if (status == 403) return _withServerHint('没有访问权限，请检查账号权限、密钥或目录访问规则', error);
    if (status == 404) return _withServerHint('服务器地址或远端目录不存在', error);
    if (status == 405) return _withServerHint('服务器不接受该请求方法，请确认地址指向支持 WebDAV 的目录', error);
    if (status == 409) return _withServerHint('远端路径冲突，请检查远端目录下是否存在同名目录', error);
    if (status == 412) return _withServerHint('远端文件已被其他设备修改，请先同步后再重试', error);
    if (status == 423) return _withServerHint('远端文件被服务器锁定，请稍后再试', error);
    if (status == 429 || status == 503) return _withServerHint('服务端请求过于频繁，请稍后再试', error);
    if (status == 507 || status == 509) return _withServerHint('云端空间不足，请清理网盘或对象存储后重试', error);
    if (status != null) return _withServerHint('服务器返回错误（HTTP $status）', error);

    // 未收到响应时按异常类型给出更具体的指引
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
        return '连接服务器超时，请检查网络、地址与端口是否正确';
      case DioExceptionType.sendTimeout:
        return '上传超时，请检查网络状况后重试';
      case DioExceptionType.receiveTimeout:
        return '服务器响应超时，请稍后重试';
      default:
        break;
    }

    final text = error.error?.toString() ?? error.message ?? '';
    if (text.contains('HandshakeException') ||
        text.contains('CERTIFICATE_VERIFY_FAILED') ||
        text.contains('certificate')) {
      return '服务器证书校验失败，自建服务可在连接设置中开启「忽略证书错误」';
    }
    if (text.contains('Connection refused') || text.contains('SocketException')) {
      return '无法连接到服务器，请检查地址、端口与服务是否已启动';
    }
    return '无法连接到服务器，请检查网络与服务器地址';
  }
  return error.toString();
}

/// 只是把状态码换了个说法的响应文本，展示出来对用户没有帮助
const Set<String> _genericServerTexts = {
  'bad request',
  'conflict',
  'error',
  'forbidden',
  'insufficient storage',
  'internal server error',
  'locked',
  'not found',
  'ok',
  'precondition failed',
  'service unavailable',
  'too many requests',
  'unauthorized',
};

/// 在提示后追加服务端给出的原因
///
/// 网盘与自建服务常在响应体里写明失败原因（空间不足、路径被占用、只读挂载等），
/// 这些信息比状态码更有指向性
String _withServerHint(String base, DioException error) {
  final hint = _serverHintOf(error);
  if (hint == null || base.contains(hint)) return base;
  return '$base（服务端说明：$hint）';
}

/// 从异常中提取服务端说明，取不到有用内容时返回 null
String? _serverHintOf(DioException error) {
  final raw = _rawServerTextOf(error);
  if (raw == null) return null;

  var text = raw;
  // XML 响应优先取 message / responsedescription 节点
  final match = RegExp(
    r'<(?:[a-zA-Z]+:)?(?:message|responsedescription)>([^<]{1,200})<',
    caseSensitive: false,
  ).firstMatch(text);
  if (match != null) text = match.group(1) ?? '';
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

  if (text.isEmpty) return null;
  // 无法解析的结构化内容（如整页 HTML 错误页）直接忽略，避免把标记当成提示
  if (text.startsWith('<')) return null;
  if (_genericServerTexts.contains(text.toLowerCase())) return null;
  return text.length > 80 ? '${text.substring(0, 80)}…' : text;
}

/// 读取异常携带的原始响应文本
String? _rawServerTextOf(DioException error) {
  final custom = error.error;
  if (custom is String && custom.trim().isNotEmpty) return custom;

  final data = error.response?.data;
  if (data is String && data.trim().isNotEmpty) return data;
  return null;
}
