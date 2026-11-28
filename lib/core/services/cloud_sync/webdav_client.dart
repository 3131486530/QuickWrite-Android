import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:quick_write/core/services/cloud_sync/remote_storage.dart';
import 'package:quick_write/core/services/cloud_sync/sync_models.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

/// WebDAV 客户端封装
///
/// 在 webdav_client 的基础上提供：
/// - 服务器地址校验，默认要求 HTTPS，避免账号密码以明文传输；
///   自建 NAS 等内网环境可显式允许 http:// 与自签证书
/// - 统一的连接与传输超时
/// - 请求节流与限流退避，避免触发网盘的访问频率限制
/// - 重试时重新打开本地文件流，避免流被消费后重试上传空内容
///
/// 该类只负责与远端服务器的通信，不感知具体的同步业务逻辑
class WebDavClient implements RemoteStorage {
  // ================= 常量定义 =================

  /// 建立连接的超时时间（毫秒）
  static const int _connectTimeout = 15000;

  /// 发送数据的超时时间（毫秒）
  static const int _sendTimeout = 180000;

  /// 接收数据的超时时间（毫秒）
  static const int _receiveTimeout = 180000;

  /// 普通临时错误的最大重试次数
  static const int _maxRetries = 3;

  /// 服务端限流时的最大重试次数
  ///
  /// 网盘的访问频率限制通常按较长的时间窗口计算，短时间内重试没有意义，
  /// 因此重试次数较少、等待时间较长，超过后交由上层中止本轮同步
  static const int _maxRateLimitRetries = 3;

  /// 相邻两次请求之间的最小间隔
  ///
  /// 网盘普遍对 WebDAV 请求频率有严格限制（例如每 30 分钟数百次），
  /// 保持间隔可以让长时间同步不至于迅速耗尽配额
  static const Duration _minRequestInterval = Duration(milliseconds: 300);

  /// 请求间隔放宽后的上限
  static const Duration _maxRequestInterval = Duration(seconds: 5);

  /// 坚果云的起始请求间隔
  ///
  /// 坚果云对每 30 分钟的 WebDAV 请求次数有硬上限（免费账号约 600 次），
  /// 按 800ms 的间隔发起请求才不会在长同步中撞上线
  static const Duration _jianguoyunRequestInterval =
      Duration(milliseconds: 800);

  /// 按服务端选择起始请求间隔
  static Duration _initialIntervalFor(String serverUrl) =>
      isJianguoyunHost(serverUrl)
      ? _jianguoyunRequestInterval
      : _minRequestInterval;

  /// 服务端限流时的退避基数
  static const Duration _rateLimitBaseDelay = Duration(seconds: 5);

  /// 单次重试等待的上限
  static const Duration _maxRetryDelay = Duration(seconds: 30);

  /// 坚果云单次重试等待的上限
  ///
  /// 坚果云的频率限制按分钟级窗口恢复，短等反复试探只会把冷却窗口不断推后，
  /// 因此允许更长的单次等待
  static const Duration _jianguoyunMaxRetryDelay = Duration(seconds: 60);

  /// 普通临时错误的基础等待时间
  static const Duration _retryBaseDelay = Duration(milliseconds: 800);

  /// 不作为普通文件同步的远端内部目录
  static const Set<String> _internalDirNames = {
    '.quickwrite', // 同步元数据
    '.trash', // 软删除文件
    '.snapshots', // 首次同步前的整包快照
  };

  /// 递归列举结果的有效期
  ///
  /// 同步过程通常在数分钟内完成，期间远端只会有本端自身的写入；
  /// 缓存过期时间远小于同步间隔，既能复用结果，也不会读到过旧的数据
  static const Duration _listCacheTtl = Duration(seconds: 20);

  /// 递归列举允许的最大目录深度
  ///
  /// 正常书稿结构的层级很浅，设置上限可以防止服务端返回异常目录时陷入无限展开
  static const int _maxListDepth = 32;

  /// 一次性列举（PROPFIND Depth: infinity）的请求体
  static const String _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/>'
      '<d:getcontentlength/><d:getlastmodified/><d:getetag/></d:prop></d:propfind>';

  // ================= 构造与属性 =================

  WebDavClient({
    required this.serverUrl,
    required this.username,
    required this.password,
    required this.remoteDir,
    this.allowInsecureHttp = false,
    this.ignoreCertificateErrors = false,
  });

  /// 服务器地址
  final String serverUrl;

  /// 登录账号
  final String username;

  /// 登录密码
  final String password;

  /// 远端同步根目录（已规范化，无首尾斜杠）
  @override
  final String remoteDir;

  /// 是否允许使用未加密的 http:// 地址
  ///
  /// 仅用于内网自建服务（NAS、路由器挂载盘等）无法提供 HTTPS 的场景，
  /// 开启后账号密码会以明文传输
  final bool allowInsecureHttp;

  /// 是否忽略服务端证书错误
  ///
  /// 自建服务常用自签证书，系统的证书链校验会直接拒绝连接；
  /// 开启后接受任意证书，仅建议在自有服务器上使用
  final bool ignoreCertificateErrors;

  /// 是否直接覆盖写入目标路径
  ///
  /// 坚果云按请求次数计费（每月有明确上限），「先写临时名再移动」会让
  /// 每次上传占用两个请求，章节多时配额翻倍消耗；因此对坚果云改为直传，
  /// 目标文件被覆盖时由服务端保证写入完整性
  @override
  bool get prefersDirectUpload => isJianguoyunHost(serverUrl);

  /// 底层 WebDAV 客户端（首次使用时创建）
  webdav.Client? _rawClient;

  /// 已确认存在的远端目录，避免重复发起创建请求
  final Set<String> _ensuredDirs = {};

  /// 最近一次递归列举的结果
  ///
  /// 一次同步会多次列举同一棵目录树（预演、执行、冲突判断），
  /// 而 PROPFIND 是网盘配额消耗的大头；短时间内复用结果既能提速，
  /// 也能避免列举本身触发限流
  List<RemoteSyncFile>? _listCache;

  /// 列举结果的生成时间，用于判断缓存是否过期
  DateTime? _listCacheAt;

  /// 服务端是否拒绝了一次性列举
  ///
  /// 记为 true 后不再重复试探：试探本身也要一个请求，
  /// 对按请求计费的网盘没必要每次同步都白花一次
  bool _infinityListUnsupported = false;

  /// 多状态响应中单个 response 块
  static final RegExp _responseBlockPattern = RegExp(
    r'<(?:[A-Za-z0-9_.\-]+:)?response[\s>][\s\S]*?</(?:[A-Za-z0-9_.\-]+:)?response>',
    caseSensitive: false,
  );

  /// 标识目录条目的 collection 标签
  static final RegExp _collectionTagPattern = RegExp(
    r'<(?:[A-Za-z0-9_.\-]+:)?collection\b',
    caseSensitive: false,
  );

  /// 请求节流器
  ///
  /// 延迟创建：不同服务端的配额宽严差别很大，需要按实际地址选择起始间隔
  late final _RequestThrottle _throttle = _RequestThrottle(
    initialInterval: _initialIntervalFor(serverUrl),
    maxInterval: _maxRequestInterval,
  );

  /// 生成退避抖动用的随机数
  final math.Random _random = math.Random();

  // ================= 连接操作 =================

  /// 判断服务器地址是否合法
  ///
  /// 要求地址格式正确；默认只接受 HTTPS，[allowHttp] 为 true 时同时接受 HTTP
  static bool isValidServerUrl(String url, {bool allowHttp = false}) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) return false;
    if (uri.scheme == 'https') return true;
    return allowHttp && uri.scheme == 'http';
  }

  /// 判断异常是否由服务端请求频率限制引起
  ///
  /// 保留该入口便于调用方以协议无关的方式判断错误类型，
  /// 具体实现由 [isRemoteRateLimitError] 统一提供
  static bool isRateLimitError(Object error) => isRemoteRateLimitError(error);

  /// 将通信过程中的异常转换为便于用户理解的提示文本
  static String describeError(Object error) => describeRemoteError(error);

  /// 测试与服务器的连接是否可用
  ///
  /// 优先使用底层客户端的 ping；部分服务端（如个别 NAS 内置 WebDAV）
  /// 不支持 OPTIONS/HEAD 探测，会返回 405/501，此时退化为对同步目录做
  /// 一次零深度 PROPFIND，只要能完成鉴权即视为连接可用。
  /// 同步目录尚未创建（404）同样说明地址与凭据有效。
  @override
  Future<void> ping() async {
    try {
      await _withRetry(() => _client.ping());
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 404) return;
      if (status != 405 && status != 501) rethrow;
      try {
        await _request(
          'PROPFIND',
          remoteDir.isEmpty ? '/' : remoteDir,
          optionsHandler: (options) => options.headers?['depth'] = '0',
        );
      } on DioException catch (inner) {
        if (inner.response?.statusCode == 404) return;
        rethrow;
      }
    }
  }

  /// 确保远端目录存在（不存在时逐级创建）
  @override
  Future<void> ensureDirectory(String path) =>
      _withRetry(() => _client.mkdirAll(path));

  /// 清除已创建目录的缓存
  ///
  /// 远端目录被整体删除后，缓存中的目录已不存在，需要重新创建；
  /// 文件列表同样可能因目录重建而变化，一并失效
  @override
  void resetDirectoryCache() {
    _ensuredDirs.clear();
    _invalidateListCache();
  }

  /// 递归列出远端同步目录下的全部文件
  ///
  /// WebDAV 的单次列举只覆盖一层目录，因此按目录逐层展开。
  /// 返回结果中的逻辑键为相对于同步根目录的路径，内部目录不会进入结果
  @override
  Future<List<RemoteSyncFile>> listFilesRecursive() async {
    // 缓存仍有效时直接复用，避免对同一棵目录树重复发起 PROPFIND
    final cached = _listCache;
    final cachedAt = _listCacheAt;
    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _listCacheTtl) {
      return List<RemoteSyncFile>.of(cached);
    }

    // 先尝试一次请求拉取整棵树，服务端不支持该深度时再逐层展开
    final atOnce = await _listTreeOnce();
    if (atOnce != null) {
      _listCache = List<RemoteSyncFile>.of(atOnce);
      _listCacheAt = DateTime.now();
      return List<RemoteSyncFile>.of(atOnce);
    }

    final files = <RemoteSyncFile>[];
    // 待展开的目录队列，元素为相对于同步根目录的目录路径与当前深度，
    // 空字符串表示根目录
    final pendingDirs = <(String, int)>[('', 0)];

    while (pendingDirs.isNotEmpty) {
      final (relativeDir, depth) = pendingDirs.removeAt(0);
      final remotePath = relativeDir.isEmpty
          ? remoteDir
          : '$remoteDir/$relativeDir';

      final entries = await _withRetry(() => _client.readDir(remotePath));
      for (final entry in entries) {
        final name = entry.name;
        if (name == null || name.isEmpty) continue;

        final relativePath = relativeDir.isEmpty ? name : '$relativeDir/$name';
        if (entry.isDir == true) {
          // 内部目录不参与文件同步
          if (_internalDirNames.contains(name)) continue;
          // 超过深度上限的目录不再展开，防止异常结构导致无限列举
          if (depth + 1 > _maxListDepth) continue;
          pendingDirs.add((relativePath, depth + 1));
          continue;
        }

        // 跳过传输中断残留的临时文件
        if (name.endsWith(kSyncTempSuffix)) continue;

        files.add(
          RemoteSyncFile(
            key: relativePath,
            // 与一次性列举走同一套规范化，避免两条路径产出的 ETag 形态不同，
            // 导致跨轮同步把未变更的文件误判为已变更
            etag: _normalizeEtag(entry.eTag ?? ''),
            size: entry.size ?? 0,
            modifiedAt: entry.mTime,
          ),
        );
      }
    }

    _listCache = List<RemoteSyncFile>.of(files);
    _listCacheAt = DateTime.now();
    return files;
  }

  /// 一次性列举整棵目录树
  ///
  /// 逐层列举每进一个目录都要一次 PROPFIND，书稿目录一多，单次同步的请求数
  /// 就成倍上涨；支持该深度的服务端一次请求即可返回全树。服务端禁用
  /// Depth: infinity 或返回无法解析的内容时返回 null，由调用方回落逐层列举
  Future<List<RemoteSyncFile>?> _listTreeOnce() async {
    if (_infinityListUnsupported) return null;

    final Response<dynamic> response;
    try {
      response = await _request(
        'PROPFIND',
        remoteDir,
        data: _propfindBody,
        optionsHandler: (options) {
          options.responseType = ResponseType.plain;
          options.headers = {
            ...?options.headers,
            'depth': 'infinity',
            'content-type': 'application/xml; charset=utf-8',
          };
        },
      );
    } on DioException catch (e) {
      // 目录尚未创建，等同于空目录
      if (e.response?.statusCode == 404) return const <RemoteSyncFile>[];
      _infinityListUnsupported = true;
      debugPrint('服务端不接受一次性列举（${e.response?.statusCode}），回落逐层列举');
      return null;
    }

    final body = response.data;
    if (body is! String || body.trim().isEmpty) {
      _infinityListUnsupported = true;
      return null;
    }

    final parsed = _parseTreeOf(body);
    if (parsed == null) {
      _infinityListUnsupported = true;
      debugPrint('一次性列举结果无法解析，回落逐层列举');
      return null;
    }
    return parsed;
  }

  /// 解析多状态响应，得到整棵树的文件列表
  ///
  /// 只依赖正则读取标签值，不引入额外的 XML 依赖；结构异常时返回 null
  List<RemoteSyncFile>? _parseTreeOf(String xml) {
    final blocks = _responseBlockPattern.allMatches(xml).toList();
    if (blocks.isEmpty) return null;

    final files = <RemoteSyncFile>[];
    var fileEntries = 0;
    for (final block in blocks) {
      final raw = block.group(0);
      if (raw == null) continue;

      // 先按 resourcetype 判断是不是目录，目录本身不计入文件数
      final isCollection = _collectionTagPattern.hasMatch(raw);
      if (!isCollection) fileEntries++;
      if (isCollection) continue;

      final href = _propValue(raw, 'href');
      if (href == null) continue;

      final key = _relativeKeyOf(href);
      if (key == null || key.isEmpty) continue;

      final segments = key.split('/');
      // 内部目录与传输残留的临时文件都不属于同步范围
      if (segments.any((seg) => _internalDirNames.contains(seg))) continue;
      if (segments.last.endsWith(kSyncTempSuffix)) continue;
      if (segments.length > _maxListDepth) continue;

      files.add(
        RemoteSyncFile(
          key: key,
          etag: _normalizeEtag(_propValue(raw, 'getetag') ?? ''),
          size: int.tryParse(_propValue(raw, 'getcontentlength') ?? '') ?? 0,
          modifiedAt: _parseHttpDate(_propValue(raw, 'getlastmodified')),
        ),
      );
    }

    // 响应里明明有文件条目却一条都没换算出来，说明路径结构与本端假设不符；
    // 宁可回落逐层列举，也不能把非空远端当成空目录
    if (files.isEmpty && fileEntries > 0) return null;
    return files;
  }

  /// 把响应中的 href 换算成相对于同步根目录的逻辑键
  String? _relativeKeyOf(String href) {
    final String decoded;
    try {
      decoded = Uri.decodeComponent(href.trim());
    } on FormatException {
      // href 里出现非法的百分号转义时无法还原路径，按未知条目处理
      return null;
    }
    if (decoded.isEmpty) return null;

    final root = remoteDir.replaceAll(RegExp(r'^/+|/+$'), '');
    if (root.isEmpty) {
      final trimmed = decoded.replaceAll(RegExp(r'^/+|/+$'), '');
      return trimmed.isEmpty ? null : trimmed;
    }

    final marker = '/$root/';
    final index = decoded.indexOf(marker);
    if (index < 0) return null;
    final key = decoded.substring(index + marker.length);
    return key.endsWith('/') ? key.substring(0, key.length - 1) : key;
  }

  /// 读取多状态响应中某个属性标签的文本值
  static String? _propValue(String block, String tag) {
    final match = RegExp(
      '<(?:[A-Za-z0-9_.\\-]+:)?'
      '$tag'
      r'\b[^>]*>([\s\S]*?)</',
      caseSensitive: false,
    ).firstMatch(block);
    final value = match?.group(1)?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  /// 统一 ETag 表示，去掉弱校验前缀与包裹引号
  static String _normalizeEtag(String raw) {
    var value = raw.trim();
    if (value.startsWith('W/')) value = value.substring(2);
    if (value.length >= 2 &&
        value.startsWith('"') &&
        value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    return value;
  }

  /// 解析 HTTP 日期，失败时返回 null
  static DateTime? _parseHttpDate(String? raw) {
    if (raw == null) return null;
    try {
      return HttpDate.parse(raw);
    } on Object {
      return null;
    }
  }

  /// 把远端绝对路径换算成逻辑键
  String? _keyOfRemotePath(String remotePath) {
    final root = remoteDir.replaceAll(RegExp(r'^/+|/+$'), '');
    final path = remotePath.replaceAll(RegExp(r'^/+|/+$'), '');
    if (root.isEmpty) return path.isEmpty ? null : path;
    if (path == root) return null;
    final prefix = '$root/';
    if (!path.startsWith(prefix)) return null;
    return path.substring(prefix.length);
  }

  /// 把一次成功的上传合并进列举缓存
  ///
  /// 直接清空缓存会让后续每个阶段都重新发起 PROPFIND；对按请求计费的网盘，
  /// 一轮同步里多出的两轮列举就是实打实的配额消耗。只有服务端回了 ETag、
  /// 能确定远端新状态时才走补丁，否则退回整表失效——
  /// 宁可多一次请求，也不能让快照与远端不一致
  void _patchCacheAfterUpload(
    String remotePath,
    Response<dynamic> response,
    int size,
  ) {
    final key = _keyOfRemotePath(remotePath);
    final etag = _normalizeEtag(response.headers.value('etag') ?? '');
    if (key == null || etag.isEmpty) {
      _invalidateListCache();
      return;
    }
    _upsertCacheEntry(
      RemoteSyncFile(key: key, etag: etag, size: size),
    );
  }

  /// 把一次成功的删除合并进列举缓存
  void _patchCacheAfterDelete(String remotePath) {
    final key = _keyOfRemotePath(remotePath);
    final cache = _listCache;
    if (key == null || cache == null) {
      _invalidateListCache();
      return;
    }
    cache.removeWhere((entry) => entry.key == key);
  }

  /// 就地替换缓存中的同一个逻辑键
  void _upsertCacheEntry(RemoteSyncFile entry) {
    final cache = _listCache;
    if (cache == null) return;
    cache.removeWhere((item) => item.key == entry.key);
    cache.add(entry);
  }

  /// 使递归列举缓存失效
  ///
  /// 任何会改变远端文件集合的操作完成后都必须调用，
  /// 否则后续读取可能拿到写入前的旧列表
  void _invalidateListCache() {
    _listCache = null;
    _listCacheAt = null;
  }

  /// 丢弃底层连接并在下次请求时重建
  ///
  /// 网络中断、代理切换后 Dio 的连接池可能保留了已失效的连接，
  /// 继续复用会让后续请求持续失败，因此整体丢弃重建
  void _resetTransport() {
    _rawClient?.c.close(force: true);
    _rawClient = null;
    _ensuredDirs.clear();
    _infinityListUnsupported = false;
    _invalidateListCache();
  }

  /// 释放底层连接资源
  @override
  void dispose() {
    _rawClient?.c.close(force: true);
    _rawClient = null;
    _ensuredDirs.clear();
    _infinityListUnsupported = false;
    _invalidateListCache();
  }

  // ================= 文件传输 =================

  /// 将逻辑键转换为远端绝对路径
  @override
  String remotePathOf(String key) => '$remoteDir/$key';

  /// 上传本地文件到远端
  ///
  /// 直接发起 PUT，跳过 webdav_client 内部为兼容摘要认证而附加的预检请求，
  /// 从而显著减少请求次数
  @override
  Future<void> uploadFile(String localPath, String remotePath) async {
    final file = File(localPath);
    final length = await file.length();
    late final Response<dynamic> response;
    try {
      // 直传模式先直接写入：增量同步时远端目录通常已经存在，
      // 预先建目录等于每次同步都白付一个请求
      response = await _uploadFileOnce(
        file,
        length,
        remotePath,
        ensureParent: !prefersDirectUpload,
      );
    } on DioException catch (e) {
      // 父目录缺失（被其他客户端删除）时服务端返回 404 或 409；
      // 清空目录缓存、重新创建父目录后重试一次
      final status = e.response?.statusCode;
      if (status != 409 && status != 404) rethrow;
      resetDirectoryCache();
      response = await _uploadFileOnce(
        file,
        length,
        remotePath,
        ensureParent: true,
      );
    }
    _patchCacheAfterUpload(remotePath, response, length);
  }

  /// 执行一次上传尝试
  Future<Response<dynamic>> _uploadFileOnce(
    File file,
    int length,
    String remotePath, {
    bool ensureParent = true,
  }) async {
    if (ensureParent) await _ensureParentDirectory(remotePath);

    return _request(
      'PUT',
      remotePath,
      // 每次尝试都重新打开文件流：流只能被消费一次，
      // 复用同一个流会让重试变成空上传，服务端上的文件被截断为 0 字节
      dataBuilder: () => file.openRead(),
      optionsHandler: (options) => options.headers?['content-length'] = length,
    );
  }

  /// 上传内存中的字节数据到远端
  ///
  /// 用于上传归档包等已在内存中生成的内容
  @override
  Future<void> uploadBytes(Uint8List bytes, String remotePath) async {
    await _ensureParentDirectory(remotePath);

    final response = await _request(
      'PUT',
      remotePath,
      data: bytes,
      optionsHandler: (options) =>
          options.headers?['content-length'] = bytes.length,
    );
    _patchCacheAfterUpload(remotePath, response, bytes.length);
  }

  /// 下载远端文件到内存
  @override
  Future<Uint8List> downloadBytes(String remotePath) async {
    final response = await _request(
      'GET',
      remotePath,
      optionsHandler: (options) => options.responseType = ResponseType.bytes,
    );

    // 重定向由底层 HTTP 客户端自动跟随；此处仍收到 3xx 时说明重定向未被处理，
    // 直接给出明确错误，避免把响应体当作文件内容写入
    final status = response.statusCode;
    if (status != null && status >= 300 && status < 400) {
      final location = response.headers.value('location');
      throw StateError(
        '远端文件下载被重定向，但客户端未自动跟随'
        '${location == null || location.isEmpty ? '' : '（目标：$location）'}',
      );
    }

    return Uint8List.fromList(response.data as List<int>);
  }

  /// 下载远端文件到内存，文件不存在时返回 null
  @override
  Future<Uint8List?> downloadBytesIfExists(String remotePath) async {
    try {
      return await downloadBytes(remotePath);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  /// 列出远端指定目录下的直接文件名，目录不存在时返回空列表
  @override
  Future<List<String>> listFileNames(String remotePath) async {
    final entries = await _listEntries(remotePath);
    return [
      for (final entry in entries)
        if (entry.isDir != true && entry.name != null && entry.name!.isNotEmpty)
          entry.name!,
    ];
  }

  /// 列出远端指定目录下的子目录名，目录不存在时返回空列表
  @override
  Future<List<String>> listDirectoryNames(String remotePath) async {
    final entries = await _listEntries(remotePath);
    return [
      for (final entry in entries)
        if (entry.isDir == true && entry.name != null && entry.name!.isNotEmpty)
          entry.name!,
    ];
  }

  /// 递归删除远端目录
  ///
  /// 目录内可能包含大量条目，优先请求服务端整目录删除；
  /// 服务端不支持时退化为逐个条目删除
  @override
  Future<void> deleteDirectoryRecursive(String remotePath) async {
    if (await _tryDeleteCollection(remotePath)) return;

    final entries = await _listEntries(remotePath);
    for (final entry in entries) {
      final name = entry.name;
      if (name == null || name.isEmpty) continue;

      final childPath = '$remotePath/$name';
      if (entry.isDir == true) {
        await deleteDirectoryRecursive(childPath);
      } else {
        await deleteFile(childPath);
      }
    }

    try {
      await deleteFile(remotePath);
    } on DioException {
      // 部分服务端拒绝删除目录本身，目录内已无内容时视为删除完成
      final remaining = await _listEntries(remotePath);
      if (remaining.isNotEmpty) rethrow;
      debugPrint('服务端未删除目录本身，目录内容已清空: $remotePath');
    }
  }

  /// 清空远端目录内的全部内容
  ///
  /// 只清理目录内的内容并保留目录本身，
  /// 避免因服务端不允许删除该目录而误报失败
  @override
  Future<void> clearDirectory(String remotePath) async {
    final entries = await _listEntries(remotePath);
    for (final entry in entries) {
      final name = entry.name;
      if (name == null || name.isEmpty) continue;

      final childPath = '$remotePath/$name';
      if (entry.isDir == true) {
        await deleteDirectoryRecursive(childPath);
      } else {
        await deleteFile(childPath);
      }
    }
  }

  /// 尝试一次性删除目录，成功返回 true
  Future<bool> _tryDeleteCollection(String remotePath) async {
    try {
      await _request('DELETE', remotePath);
      return true;
    } on DioException catch (e) {
      // 目录不存在时视为删除完成
      if (e.response?.statusCode == 404) return true;
      debugPrint('服务端未能整目录删除，改为逐个删除: $remotePath');
      return false;
    }
  }

  /// 列出目录下的原始条目，目录不存在时返回空列表
  Future<List<webdav.File>> _listEntries(String remotePath) async {
    try {
      return await _withRetry(() => _client.readDir(remotePath));
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return const [];
      rethrow;
    }
  }

  /// 下载远端文件到本地指定路径
  ///
  /// 目标文件已有部分内容时带上 Range 续传剩余部分，避免弱网下大文件
  /// 反复从头下载白白消耗流量；服务端不支持续传而返回完整内容时整份覆盖写入
  @override
  Future<void> downloadFile(String remotePath, String localPath) async {
    final target = File(localPath);
    var received = await target.exists() ? await target.length() : 0;

    await _withRetry(() async {
      final response = await _client.c.req<dynamic>(
        _client,
        'GET',
        remotePath,
        optionsHandler: (options) {
          options.responseType = ResponseType.bytes;
          if (received > 0) {
            options.headers = {
              ...?options.headers,
              'range': 'bytes=$received-',
            };
          }
        },
      );

      final status = response.statusCode ?? 0;
      // 本地残留内容已经无法接续（远端文件变小或已更换），删掉后整份重下
      if (status == 416) {
        if (await target.exists()) await target.delete();
        received = 0;
        throw _badResponseError(response);
      }
      if (status != 200 && status != 206) throw _badResponseError(response);

      final data = response.data;
      if (data is! List<int>) {
        throw DioException(
          requestOptions: response.requestOptions,
          response: response,
          type: DioExceptionType.badResponse,
          error: '服务端未返回文件内容',
        );
      }

      // 服务端支持续传时追加剩余部分，返回完整内容时从头覆盖
      final append = status == 206 && received > 0;
      final raf = await target.open(
        mode: append ? FileMode.append : FileMode.write,
      );
      try {
        await raf.writeFrom(data);
        await raf.flush();
      } finally {
        await raf.close();
        // 记录已落盘的字节数，本次中断后重试可从断点继续
        received = await target.length();
      }
    });
  }

  /// 移动远端文件
  ///
  /// 部分服务端不支持 MOVE 覆盖已存在的目标，遇到目标冲突时先删除目标再重试，
  /// 从而在保留 MOVE 原子替换特性的同时兼容这类服务端。
  /// 直接发起 MOVE，跳过内部预检请求
  @override
  Future<void> moveFile(
    String fromPath,
    String toPath, {
    bool overwrite = true,
  }) async {
    try {
      await _moveOnce(fromPath, toPath, overwrite: overwrite);
    } on DioException catch (e) {
      if (!overwrite || !_isTargetConflict(e)) rethrow;
      await deleteFile(toPath);
      await _moveOnce(fromPath, toPath, overwrite: overwrite);
    }
    _invalidateListCache();
  }

  /// 删除远端文件
  ///
  /// 文件已不存在时视为删除成功，便于重试
  @override
  Future<void> deleteFile(String remotePath) async {
    try {
      await _request('DELETE', remotePath);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        _patchCacheAfterDelete(remotePath);
        return;
      }
      rethrow;
    }
    _patchCacheAfterDelete(remotePath);
  }

  /// 发起一次 MOVE 请求
  Future<void> _moveOnce(
    String fromPath,
    String toPath, {
    required bool overwrite,
  }) async {
    await _request(
      'MOVE',
      fromPath,
      optionsHandler: (options) {
        options.headers?['destination'] = _absoluteUrlOf(toPath);
        options.headers?['overwrite'] = overwrite ? 'T' : 'F';
      },
    );
  }

  /// 判断异常是否表示移动目标已存在
  bool _isTargetConflict(DioException error) {
    final status = error.response?.statusCode;
    // 409 表示目标冲突，412 表示目标已存在且服务端未允许覆盖
    return status == 409 || status == 412;
  }

  /// 读取远端文件属性
  @override
  Future<RemoteSyncFile> fileInfo(String key) async {
    final file = await _withRetry(() => _client.readProps(remotePathOf(key)));
    return RemoteSyncFile(
      key: key,
      etag: file.eTag ?? '',
      size: file.size ?? 0,
      modifiedAt: file.mTime,
    );
  }

  /// 判断远端文件是否存在
  @override
  Future<bool> exists(String key) async {
    try {
      await _withRetry(() => _client.readProps(remotePathOf(key)));
      return true;
    } on DioException catch (e) {
      // 404 表示文件不存在，其余错误继续向上抛出
      if (e.response?.statusCode == 404) return false;
      rethrow;
    }
  }

  // ================= 内部实现 =================

  /// 获取底层客户端，首次访问时按配置创建
  webdav.Client get _client {
    if (_rawClient != null) return _rawClient!;

    if (!isValidServerUrl(serverUrl, allowHttp: allowInsecureHttp)) {
      throw ArgumentError(
        allowInsecureHttp
            ? '服务器地址无效，请填写以 http:// 或 https:// 开头的完整地址'
            : '服务器地址无效，请填写以 https:// 开头的完整地址',
      );
    }

    final client = webdav.newClient(
      serverUrl,
      user: username,
      password: password,
    );
    if (ignoreCertificateErrors) {
      // 自签证书不受系统信任链保护，需要自行放行；连接超时仍在适配器层设置
      client.c.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => HttpClient()
          ..connectionTimeout = const Duration(milliseconds: _connectTimeout)
          ..badCertificateCallback = (cert, host, port) => true,
      );
    }
    client.setConnectTimeout(_connectTimeout);
    client.setSendTimeout(_sendTimeout);
    client.setReceiveTimeout(_receiveTimeout);
    _rawClient = client;
    debugPrint('WebDavClient 已创建，服务器地址: ${client.uri}');
    return client;
  }

  /// 确保远端文件所在目录存在
  ///
  /// 同一目录在一次同步中只创建一次
  Future<void> _ensureParentDirectory(String remotePath) async {
    final separatorIndex = remotePath.lastIndexOf('/');
    if (separatorIndex <= 0) return;

    final parentPath = remotePath.substring(0, separatorIndex);
    if (!_ensuredDirs.add(parentPath)) return;
    await _withRetry(() => _client.mkdirAll(parentPath));
  }

  /// 拼接远端资源的绝对地址，用于 MOVE 的目标地址头
  ///
  /// 逐段编码路径，中文与空格能被正确转义，已编码的 %XX 也不会被再次编码
  String _absoluteUrlOf(String remotePath) {
    final raw = _client.uri.toString();
    final base = raw.endsWith('/') ? raw : '$raw/';
    final relative = remotePath.startsWith('/')
        ? remotePath.substring(1)
        : remotePath;
    final encoded = relative
        .split('/')
        .map((segment) => Uri.encodeComponent(segment))
        .join('/');
    return '$base$encoded';
  }

  /// 发起原始请求并校验响应状态
  ///
  /// 底层 HTTP 客户端把所有状态码都视为正常响应，因此状态校验必须放在重试闭包内，
  /// 服务端限流与临时故障才能被识别并进入统一的退避与冷却流程
  Future<Response<dynamic>> _request(
    String method,
    String path, {
    dynamic data,
    dynamic Function()? dataBuilder,
    void Function(Options options)? optionsHandler,
  }) {
    return _withRetry(() async {
      final response = await _client.c.req<dynamic>(
        _client,
        method,
        path,
        // 请求体可能是一次性流，每次尝试都由 dataBuilder 重新生成
        data: dataBuilder != null ? dataBuilder() : data,
        optionsHandler: optionsHandler,
      );

      final status = response.statusCode;
      if (status == null || (status >= 200 && status < 300)) return response;
      throw _badResponseError(response);
    });
  }

  /// 构造响应错误
  ///
  /// 便于上层通过状态码统一判断错误类型；服务端在响应体里给出具体原因时
  /// 一并保留，错误提示才能说明“为什么失败”而不只是状态码
  DioException _badResponseError(Response<dynamic> response) {
    return DioException(
      requestOptions: response.requestOptions,
      response: response,
      type: DioExceptionType.badResponse,
      error: _serverReasonOf(response) ?? response.statusMessage,
    );
  }

  /// 提取服务端返回的错误说明
  ///
  /// WebDAV 服务端通常在响应体中以 XML 或纯文本说明失败原因
  /// （如空间不足、目标被锁定），最多保留一小段便于展示的文本
  String? _serverReasonOf(Response<dynamic> response) {
    final data = response.data;
    if (data is! String) return null;
    if (data.isEmpty) return null;

    // 响应体可能很长（例如整目录列举的结果），只看开头即可
    final head = data.length > 2000 ? data.substring(0, 2000) : data;
    final match = RegExp(
      r'<(?:[a-zA-Z]+:)?(?:message|responsedescription)>([^<]{1,300})<',
      caseSensitive: false,
    ).firstMatch(head);
    final raw = match?.group(1) ?? (head.trimLeft().startsWith('<') ? null : head);
    if (raw == null) return null;

    final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return null;
    return text.length > 120 ? '${text.substring(0, 120)}…' : text;
  }

  // ================= 重试机制 =================

  /// 执行带自动重试的操作
  ///
  /// 每次尝试前都会经过节流，既保证请求间隔，也让服务端限流时并发的请求一并等待；
  /// 仅在出现可重试的临时性错误时重试，其余错误直接抛出
  Future<T> _withRetry<T>(Future<T> Function() action) async {
    var attempt = 0;
    while (true) {
      await _throttle.acquire();

      try {
        return await action();
      } catch (e) {
        attempt++;
        final rateLimited = isRateLimitError(e);
        final maxAttempts = rateLimited ? _maxRateLimitRetries : _maxRetries;
        // 配额耗尽重试也不会成功，继续重试只会白白消耗剩余配额
        if (!_isRetryable(e) ||
            isRemoteQuotaExceeded(e) ||
            attempt > maxAttempts) {
          // 连接级失败（断网、切换网络、代理抖动）后底层连接池可能已失效，
          // 继续复用会让后续请求持续失败，此处丢弃连接以便下次重建
          if (_isTransportFailure(e)) _resetTransport();
          rethrow;
        }

        // 放宽请求间隔并进入全局冷却，避免并发的其他请求继续冲击已被限流的服务端
        if (rateLimited) _throttle.slowDown();
        _throttle.cooldown(_retryDelayFor(e, attempt));
      }
    }
  }

  /// 判断错误是否属于连接级失败
  ///
  /// 这类失败与当前连接本身有关（而不是某次请求的内容），
  /// 重建连接后往往可以立即恢复
  bool _isTransportFailure(Object error) {
    if (error is! DioException) return false;
    if (error.response?.statusCode != null) return false;

    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.badCertificate:
      case DioExceptionType.badResponse:
      case DioExceptionType.cancel:
      case DioExceptionType.transformTimeout:
      case DioExceptionType.unknown:
        return false;
    }
  }

  /// 判断错误是否属于可重试的临时性错误
  bool _isRetryable(Object error) {
    if (error is! DioException) return false;

    final status = error.response?.statusCode;
    // 未收到响应，通常是网络中断或请求超时
    if (status == null) return true;
    // 请求过于频繁或服务端临时故障
    return status == 429 || status >= 500;
  }

  /// 计算重试前的等待时长
  ///
  /// 服务端限流时采用指数退避并附加随机抖动，避免多个并发请求同时重试
  Duration _retryDelayFor(Object error, int attempt) {
    final maxWait = isJianguoyunHost(serverUrl)
        ? _jianguoyunMaxRetryDelay
        : _maxRetryDelay;

    // 服务端给出 Retry-After 时按服务端要求等待，避免无效重试继续冲击配额
    final serverDelay = _retryAfterOf(error);
    if (serverDelay != null) {
      return serverDelay > maxWait ? maxWait : serverDelay;
    }

    if (!isRateLimitError(error)) {
      return _retryBaseDelay * attempt;
    }

    final exponential = _rateLimitBaseDelay * (1 << (attempt - 1));
    final capped = exponential > maxWait ? maxWait : exponential;
    return capped + Duration(milliseconds: _random.nextInt(500));
  }

  /// 解析响应头中的 Retry-After
  ///
  /// 支持秒数与 HTTP 日期两种格式，解析失败时返回 null
  Duration? _retryAfterOf(Object error) {
    if (error is! DioException) return null;
    final raw = error.response?.headers.value('retry-after');
    if (raw == null || raw.trim().isEmpty) return null;

    final seconds = int.tryParse(raw.trim());
    if (seconds != null) {
      return seconds <= 0 ? Duration.zero : Duration(seconds: seconds);
    }

    final date = DateTime.tryParse(raw.trim());
    if (date == null) return null;
    final delay = date.difference(DateTime.now());
    return delay.isNegative ? Duration.zero : delay;
  }
}

/// 请求节流器
///
/// 统一控制对远端的请求节奏：
/// - 保证相邻请求之间存在最小间隔，避免过快耗尽服务端的访问配额
/// - 服务端限流时逐步放宽间隔并进入全局冷却，冷却期内所有请求排队等待
class _RequestThrottle {
  _RequestThrottle({
    required Duration initialInterval,
    required this.maxInterval,
  }) : _interval = initialInterval;

  /// 请求间隔放宽后的上限
  final Duration maxInterval;

  /// 当前的请求间隔，服务端限流后会自动放宽
  Duration _interval;

  /// 上一次请求的发起时间
  DateTime? _lastRequestAt;

  /// 冷却截止时间
  DateTime? _cooldownUntil;

  /// 等待轮到本次请求发起
  Future<void> acquire() async {
    while (true) {
      final now = DateTime.now();

      // 处于冷却期时先等待冷却结束
      final cooldownUntil = _cooldownUntil;
      if (cooldownUntil != null && now.isBefore(cooldownUntil)) {
        await Future.delayed(cooldownUntil.difference(now));
        continue;
      }

      // 与上一次请求保持最小间隔
      final lastRequestAt = _lastRequestAt;
      if (lastRequestAt != null) {
        final earliest = lastRequestAt.add(_interval);
        if (now.isBefore(earliest)) {
          await Future.delayed(earliest.difference(now));
          continue;
        }
      }

      _lastRequestAt = DateTime.now();
      return;
    }
  }

  /// 放宽请求间隔
  ///
  /// 服务端返回限流响应时调用，使后续请求节奏逐步放缓，
  /// 最终稳定在服务端能够接受的频率附近
  void slowDown() {
    final next = _interval * 2;
    _interval = next > maxInterval ? maxInterval : next;
  }

  /// 进入冷却期
  ///
  /// 冷却期内所有请求都会被推迟
  void cooldown(Duration duration) {
    final until = DateTime.now().add(duration);
    if (_cooldownUntil == null || until.isAfter(_cooldownUntil!)) {
      _cooldownUntil = until;
    }
  }
}
