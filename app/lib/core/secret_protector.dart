import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';

/// 账号密码的落盘保护。
///
/// 存在这一层的理由很具体：OpenVPN 的 `auth-user-pass` 配置必须带着账号密码
/// 才能连上，而这份密码要跟着配置一起落盘。直接写进 `config.json` 意味着任何
/// 读得到这个文件的人（同机的其它账户、备份、云同步、误发的日志）都拿得到
/// 明文密码。
///
/// 三个实现：
///   * [DpapiSecretProtector]：Windows 上用系统 DPAPI，密钥由当前 Windows
///     账户派生。换个账户或换台机器都解不开——这是它的**特性**而不是缺陷。
///   * [LinuxSecretProtector]：Linux 上用 Secret Service（libsecret 管理的
///     系统钥匙串）。落盘的是一个不透明的 key，密码本身存在钥匙串里。
///   * [AndroidKeystoreSecretProtector]：安卓上用系统 Keystore 包一把数据密钥，
///     落在应用私有目录里的是「被包起来的密钥 + 密文」。见那个类的注释。
///   * [PlainSecretProtector]：没有系统凭据库可用的平台上的兜底。它不加密，
///     并且 [isSecure] 会如实返回 false，界面据此提示用户，而不是假装已经
///     保护好了。
///
/// 落盘时会把 [scheme] 一起写下来，因此接入更好的方案时，旧数据仍然读得出来：
/// 按记录里的 scheme 选择还原方式。
abstract class SecretProtector {
  const SecretProtector();

  /// 方案标识。与密文一起落盘。
  String get scheme;

  /// 是否真的提供了加密。用于界面如实提示，不允许谎报。
  bool get isSecure;

  /// 面向用户的一句话说明。
  String get description;

  /// 加密。返回可直接放进 JSON 的字符串。
  String protect(String plaintext);

  /// 还原。**失败返回 null 而不是抛异常**：换了 Windows 账户、换了机器、
  /// 或者文件被搬到另一台设备时解不开是正常情况，调用方需要的是
  /// 「这份凭据用不了了，请重新填一次」，而不是一个异常。
  String? unprotect(String payload);

  /// 按当前平台选择方案。
  ///
  /// [isWindows] / [isLinux] / [secretService] 仅供测试注入：Linux 分支在
  /// Windows 开发机上跑不到，而「选了哪个方案、失败时降级成什么」必须可断言。
  ///
  /// 安卓**不在这里**，因为解包 Keystore 里的密钥是一次异步的原生往返，而这个
  /// 方法是同步的（[AppState] 在构造里就要用它）。安卓那条路走 [resolve]。
  static SecretProtector forPlatform({
    bool? isWindows,
    bool? isLinux,
    SecretServiceBackend? secretService,
  }) {
    // 只缓存**纯生产调用**：Linux 上探测钥匙串要真的跑几次外部进程，而
    // [forPlatform] 每次构造 AppState 都会被调用（测试里成百上千次）。
    // 带注入参数的调用永远重新计算，测试之间因此不会互相干扰。
    final bool cacheable =
        isWindows == null && isLinux == null && secretService == null;
    if (cacheable && _cached != null) return _cached!;
    final protector = _select(
      isWindows: isWindows,
      isLinux: isLinux,
      secretService: secretService,
    );
    if (cacheable) _cached = protector;
    return protector;
  }

  static SecretProtector? _cached;

  static SecretProtector _select({
    required bool? isWindows,
    required bool? isLinux,
    required SecretServiceBackend? secretService,
  }) {
    final bool windows = isWindows ?? Platform.isWindows;
    final bool linux = isLinux ?? (!windows && Platform.isLinux);
    if (windows) {
      final dpapi = DpapiSecretProtector.tryCreate();
      if (dpapi != null) return dpapi;
    }
    if (linux) {
      final created = LinuxSecretProtector.tryCreate(
        backend: secretService ?? const SecretToolBackend(),
      );
      if (created != null) return created;
      // 降级必须如实：这里不是「平台还没接入」，而是这台机器上没有可用的
      // 钥匙串（缺 secret-tool，或守护进程不可达）。提示要能指导用户装上。
      return const PlainSecretProtector(
        note:
            '未加密（未找到可用的系统钥匙串；请安装 libsecret 提供的 secret-tool，'
            '密码将以明文保存）',
      );
    }
    return const PlainSecretProtector();
  }

  /// 平台方案，**安卓需要一次原生往返**（解开 Keystore 里的数据密钥），因此是
  /// 异步的。启动流程在构造 [AppState] 之前 await 它一次。
  ///
  /// [directory] 是应用的可写目录（安卓上是原生侧的 `filesDir`）：密钥要落在那
  /// 儿，拿不到就宁可退回不加密——写不下去的密钥意味着下次启动解不开今天写下的
  /// 密文，那种「宣称加密了、实则读不回」比明文更坏。
  ///
  /// [keystore] / [isAndroid] 仅供测试注入，理由同 [forPlatform]。
  static Future<SecretProtector> resolve({
    Directory? directory,
    KeystoreBackend keystore = const MethodChannelKeystoreBackend(),
    bool? isAndroid,
  }) async {
    final bool android =
        isAndroid ?? (defaultTargetPlatform == TargetPlatform.android);
    if (!android) return forPlatform();
    final created = await AndroidKeystoreSecretProtector.create(
      directory: directory,
      backend: keystore,
    );
    if (created != null) return created;
    // 降级必须如实。安卓上走到这里只有两种可能：没有可写目录，或者 Keystore
    // 这条链路眼下不可用（少见：极少数被裁剪过的系统）。
    return const PlainSecretProtector(
      note: '未加密（系统 Keystore 不可用；密码将以明文保存）',
    );
  }
}

// ---------------------------------------------------------------- DPAPI

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}

typedef _ProtectNative =
    Int32 Function(
      Pointer<_DataBlob>,
      Pointer<Utf16>,
      Pointer<_DataBlob>,
      Pointer<Void>,
      Pointer<Void>,
      Uint32,
      Pointer<_DataBlob>,
    );
typedef _ProtectDart =
    int Function(
      Pointer<_DataBlob>,
      Pointer<Utf16>,
      Pointer<_DataBlob>,
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<_DataBlob>,
    );

typedef _UnprotectNative =
    Int32 Function(
      Pointer<_DataBlob>,
      Pointer<Pointer<Utf16>>,
      Pointer<_DataBlob>,
      Pointer<Void>,
      Pointer<Void>,
      Uint32,
      Pointer<_DataBlob>,
    );
typedef _UnprotectDart =
    int Function(
      Pointer<_DataBlob>,
      Pointer<Pointer<Utf16>>,
      Pointer<_DataBlob>,
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<_DataBlob>,
    );

typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void>);

typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();

/// Windows DPAPI。
///
/// 走 FFI 直接调 `crypt32.dll`，不引入原生插件：这两组函数是系统自带的稳定
/// API，而多一个插件就多一份两端的构建负担。
class DpapiSecretProtector implements SecretProtector {
  DpapiSecretProtector._(
    this._protect,
    this._unprotect,
    this._localFree,
    this._getLastError,
  );

  final _ProtectDart _protect;
  final _UnprotectDart _unprotect;
  final _LocalFreeDart _localFree;
  final _GetLastErrorDart _getLastError;

  /// 系统里没有 crypt32 时返回 null，调用方退回到不加密的方案。
  ///
  /// 刻意不抛异常：一个拿不到系统加密能力的桌面环境，应该表现为「凭据不加密」
  /// 并且在界面上如实说明，而不是让整个应用起不来。
  static DpapiSecretProtector? tryCreate() {
    try {
      final crypt32 = DynamicLibrary.open('crypt32.dll');
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      return DpapiSecretProtector._(
        crypt32.lookupFunction<_ProtectNative, _ProtectDart>(
          'CryptProtectData',
        ),
        crypt32.lookupFunction<_UnprotectNative, _UnprotectDart>(
          'CryptUnprotectData',
        ),
        kernel32.lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree'),
        kernel32.lookupFunction<_GetLastErrorNative, _GetLastErrorDart>(
          'GetLastError',
        ),
      );
    } on Object {
      return null;
    }
  }

  @override
  String get scheme => 'dpapi';

  @override
  bool get isSecure => true;

  @override
  String get description => '已用 Windows 账户密钥加密（DPAPI）';

  /// `CRYPTPROTECT_UI_FORBIDDEN`：禁止弹任何界面。
  ///
  /// 后台解密时如果系统弹出一个凭据窗口，用户看到的是一个和 VPN 毫无关系的
  /// 系统对话框，而且会卡住启动流程。
  static const int _uiForbidden = 0x1;

  @override
  String protect(String plaintext) {
    final bytes = utf8.encode(plaintext);
    final inBlob = calloc<_DataBlob>();
    final outBlob = calloc<_DataBlob>();
    Pointer<Uint8> inData = nullptr;
    try {
      inData = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
      if (bytes.isNotEmpty) inData.asTypedList(bytes.length).setAll(0, bytes);
      inBlob.ref
        ..cbData = bytes.length
        ..pbData = inData;

      final ok = _protect(
        inBlob,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        _uiForbidden,
        outBlob,
      );
      if (ok == 0) {
        throw StateError('系统加密失败（错误码 ${_getLastError()}）');
      }
      final out = Uint8List.fromList(
        outBlob.ref.pbData.asTypedList(outBlob.ref.cbData),
      );
      return base64Encode(out);
    } finally {
      if (outBlob.ref.pbData != nullptr) _localFree(outBlob.ref.pbData.cast());
      if (inData != nullptr) calloc.free(inData);
      calloc.free(inBlob);
      calloc.free(outBlob);
    }
  }

  @override
  String? unprotect(String payload) {
    final Uint8List bytes;
    try {
      bytes = base64Decode(payload);
    } on FormatException {
      return null;
    }
    if (bytes.isEmpty) return null;

    final inBlob = calloc<_DataBlob>();
    final outBlob = calloc<_DataBlob>();
    final description = calloc<Pointer<Utf16>>();
    Pointer<Uint8> inData = nullptr;
    try {
      inData = calloc<Uint8>(bytes.length);
      inData.asTypedList(bytes.length).setAll(0, bytes);
      inBlob.ref
        ..cbData = bytes.length
        ..pbData = inData;

      final ok = _unprotect(
        inBlob,
        description,
        nullptr,
        nullptr,
        nullptr,
        _uiForbidden,
        outBlob,
      );
      if (ok == 0) return null; // 换了账户或换了机器：交给用户重新填一次。
      if (outBlob.ref.cbData == 0) return '';
      return utf8.decode(
        outBlob.ref.pbData.asTypedList(outBlob.ref.cbData),
        allowMalformed: true,
      );
    } on Object {
      return null;
    } finally {
      if (outBlob.ref.pbData != nullptr) _localFree(outBlob.ref.pbData.cast());
      if (description.value != nullptr) _localFree(description.value.cast());
      if (inData != nullptr) calloc.free(inData);
      calloc.free(inBlob);
      calloc.free(outBlob);
      calloc.free(description);
    }
  }
}

// ---------------------------------------------------------------- SECRET SERVICE

/// Linux Secret Service（libsecret 管理的系统钥匙串）后端。
///
/// 走 `secret-tool` 命令而不是 dart:ffi 直接调 `libsecret-1.so.0`：libsecret
/// 的写入 API（`secret_password_store_sync`）是 **C 变参函数**（schema 之后是
/// 成对的属性键值，以 NULL 结尾），dart:ffi 不支持调用变参函数，唯一的绕法是
/// 自带 C shim 或引入原生插件，代价都不小。`secret-tool` 是 libsecret 自己
/// 提供的命令行入口，语义与 API 一致，所以选它——运行依赖是发行版的
/// `libsecret-tools`（Debian/Ubuntu）/ `libsecret`（Fedora、Arch）。
///
/// 抽成接口是为了让「创建失败就降级、成功后 isSecure 才为 true」这条逻辑能被
/// 注入替身验证（开发机是 Windows，跑不到真实密钥串）。
abstract class SecretServiceBackend {
  const SecretServiceBackend();

  /// 存入一条并**读回校验**。返回是否真的写进去了。
  bool verifyRoundTrip(String account, String value);

  bool store(String account, String value);

  String? lookup(String account);

  void clear(String account);
}

/// 真实实现：调用 `secret-tool`。
class SecretToolBackend implements SecretServiceBackend {
  const SecretToolBackend();

  /// 属性名。库名与账号一起构成唯一标识，避免与用户其它钥匙串条目混淆。
  static const String _service = 'xvpn';

  /// 单条命令的等待上限（秒）。
  ///
  /// 存在的理由很具体：钥匙串守护进程可能已启动却不响应（锁屏、策略、
  /// 无头会话）。没有上限时 `secret-tool` 会把应用启动挂在一次同步调用上，
  /// 用户看到的是「点了图标没反应」。用 coreutils 的 `timeout` 兜住，
  /// 超时退出码 124 会被当成失败并降级到不加密。
  static const int _timeoutSeconds = 5;

  /// 带超时地执行命令。极少数没有 `timeout` 的极简环境退回直接执行。
  static ProcessResult _run(
    List<String> command, {
    Map<String, String>? environment,
  }) {
    try {
      return Process.runSync('timeout', <String>[
        '$_timeoutSeconds',
        ...command,
      ], environment: environment);
    } on ProcessException {
      return Process.runSync(
        command.first,
        command.sublist(1),
        environment: environment,
      );
    }
  }

  @override
  bool verifyRoundTrip(String account, String value) {
    if (!store(account, value)) return false;
    final readBack = lookup(account);
    clear(account);
    return readBack == value;
  }

  @override
  bool store(String account, String value) {
    try {
      // `secret-tool store` 从 stdin 读密码，而 Process.runSync 不能写 stdin，
      // 因此用 sh 把它从环境变量喂进去。放环境变量而不是命令行参数：
      // 命令行参数会出现在 /proc/<pid>/cmdline 里，同机任何进程都读得到。
      final result = _run(
        <String>[
          'sh',
          '-c',
          'printf %s "\$XVPN_SECRET" | secret-tool store '
              '--label "幽门凭据" service $_service account "\$1"',
          'sh',
          account,
        ],
        environment: <String, String>{'XVPN_SECRET': value},
      );
      return result.exitCode == 0;
    } on Object {
      return false;
    }
  }

  @override
  String? lookup(String account) {
    try {
      final result = _run(<String>[
        'secret-tool',
        'lookup',
        'service',
        _service,
        'account',
        account,
      ]);
      // 找不到时退出码为 1；这里不区分「不存在」与「查询失败」，
      // 都返回 null（调用方按「需要重新填」处理）。
      if (result.exitCode != 0) return null;
      final out = result.stdout as String;
      // secret-tool 会在末尾补一个换行；只去掉这一个，避免误删密码内容。
      return out.endsWith('\n') ? out.substring(0, out.length - 1) : out;
    } on Object {
      return null;
    }
  }

  @override
  void clear(String account) {
    try {
      _run(<String>[
        'secret-tool',
        'clear',
        'service',
        _service,
        'account',
        account,
      ]);
    } on Object {
      // 清理失败无所谓：下次写入会覆盖同一个 key。
    }
  }
}

/// Linux 上基于 Secret Service 的保护。
///
/// 落盘的不是密码本身，而是不透明的 key；密码存在系统钥匙串里。因此
/// `config.json` 即使被读到（备份、云同步、误发日志），也拿不到账号密码。
class LinuxSecretProtector implements SecretProtector {
  LinuxSecretProtector._(this._backend);

  final SecretServiceBackend _backend;

  /// 创建并**用一次真实往返**验证后端可用。
  ///
  /// 返回 null 表示不可用，调用方降级到 [PlainSecretProtector]。刻意不假设
  /// 「装了 libsecret 就一定行」：钥匙串守护进程可能没起、可能被策略禁用，
  /// 也可能在无头会话里根本不存在。[isSecure] 只有在这次往返真的成功了
  /// 才会为 true。
  static LinuxSecretProtector? tryCreate({
    SecretServiceBackend backend = const SecretToolBackend(),
  }) {
    final probe = 'xvpn-selftest-${DateTime.now().microsecondsSinceEpoch}';
    try {
      if (!backend.verifyRoundTrip(probe, 'ok')) return null;
    } on Object {
      return null;
    }
    return LinuxSecretProtector._(backend);
  }

  @override
  String get scheme => 'libsecret';

  /// 创建时已经验证过真实往返，所以这里可以如实为 true。
  @override
  bool get isSecure => true;

  @override
  String get description => '已用系统钥匙串加密（Secret Service / libsecret）';

  @override
  String protect(String plaintext) {
    final key = accountFor(plaintext);
    if (!_backend.store(key, plaintext)) {
      // 创建时验证过，正常不会走到这里。真失败了就抛出去让这次保存失败，
      // 而不是回退成明文写盘——静默降级到不加密是最糟的方向。
      throw StateError('系统钥匙串写入失败');
    }
    return key;
  }

  @override
  String? unprotect(String payload) => _backend.lookup(payload);

  /// 由明文派生的稳定 key。
  ///
  /// 用稳定 key 而不是每次生成随机 key：`_persist` 每次保存都会重新调
  /// [protect]，随机 key 会在钥匙串里不断堆孤儿条目。
  ///
  /// 用 FNV-1a 64 位而不是 SHA-256：后者要引入 `crypto` 依赖，而这里只是
  /// 需要在同一用户少量凭据之间不碰撞——64 位足够，且它是纯计算、可测。
  static String accountFor(String plaintext) {
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(plaintext)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return 'xvpn-${hash.toRadixString(16).padLeft(16, '0')}';
  }
}

// ---------------------------------------------------------------- 安卓 Keystore

/// Keystore 的往返调用。
///
/// 抽出来是为了让「首次生成 / 解包失败 / 通道不可用」这几条分支**能被测到**——
/// 与 [SecretServiceBackend] 同一个理由：开发机与 CI 上跑不到真的 AndroidKeyStore，
/// 而这几条分支恰好决定了凭据是加密落盘还是明文落盘，不能只靠真机肉眼确认。
abstract class KeystoreBackend {
  const KeystoreBackend();

  /// 生成一把新的数据密钥，并返回「被 Keystore 包装后的密文」与「明文密钥」。
  ///
  /// 失败返回 null（Keystore 不可用、通道没接上），调用方据此退回不加密。
  Future<({String wrapped, String key})?> generate();

  /// 用 Keystore 里的包装密钥解开数据密钥。解不开返回 null。
  Future<String?> unwrap(String wrapped);
}

/// 真实实现：走 `com.xvpn.xvpn/vpn` 通道找 `MainActivity`。
///
/// 通道名与 [MethodChannelAndroidVpnCore] / 更新安装用的是同一条，见
/// `updater.dart` 里为什么它一直保持 `com.xvpn.xvpn/vpn` 这个名字。
class MethodChannelKeystoreBackend implements KeystoreBackend {
  const MethodChannelKeystoreBackend();

  static const MethodChannel _channel = MethodChannel('com.xvpn.xvpn/vpn');

  @override
  Future<({String wrapped, String key})?> generate() async {
    final Map<Object?, Object?>? result;
    try {
      result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'generateCredentialKey',
      );
    } on PlatformException catch (e) {
      // 原生侧报错（Keystore 坏了、方法没接上）在这里收住：调用方要的是「能不能
      // 加密」这一个答案，而不是一次异常。真实原因留在日志里。
      debugPrint('生成凭据密钥失败：$e');
      return null;
    } on MissingPluginException catch (e) {
      debugPrint('原生侧没有接上凭据密钥通道：$e');
      return null;
    }
    final wrapped = result?['wrapped'];
    final key = result?['key'];
    if (wrapped is! String || key is! String) return null;
    if (wrapped.isEmpty || key.isEmpty) return null;
    return (wrapped: wrapped, key: key);
  }

  @override
  Future<String?> unwrap(String wrapped) async {
    final String? key;
    try {
      key = await _channel.invokeMethod<String>(
        'unwrapCredentialKey',
        <String, Object?>{'wrapped': wrapped},
      );
    } on PlatformException catch (e) {
      debugPrint('解开凭据密钥失败：$e');
      return null;
    } on MissingPluginException catch (e) {
      debugPrint('原生侧没有接上凭据密钥通道：$e');
      return null;
    }
    return (key == null || key.isEmpty) ? null : key;
  }
}

/// 安卓上基于系统 Keystore 的保护。
///
/// 与另外两个实现的差别在**密钥从哪来**：DPAPI 的密钥由当前 Windows 账户派生，
/// Linux 的密码本体存在钥匙串里，而 `AndroidKeyStore` 里的密钥**不可导出**，
/// 也就不能直接拿它加密任意长度的数据——Keystore 只肯做「一次加解密」，而且
/// 只能经 Java 侧调用，必然是异步的。
///
/// 而 [protect] / [unprotect] 必须是同步的：账号密码在 `AppState` 的**构造**里
/// 就要恢复出来（见那里的注释）。把它们改成异步，等于让界面先显示一份「没有
/// 密码的配置」——最坏情况下会带着空凭据去建隧道。
///
/// 所以这里用的是官方 `EncryptedSharedPreferences` 同一套结构：Keystore 里放一把
/// AES-256 的**包装密钥**（不可导出），启动时（[create]）用它解开一把随机的数据
/// 密钥（DEK），之后真正加密账号密码的是那把 DEK。落盘的是「被 Keystore 包起来
/// 的 DEK」（[wrappedKeyFileName]）和「DEK 加密后的密文」，而解开 DEK 的唯一手段
/// 在那台设备的 Keystore 里——**换台设备、或从云备份恢复出来的这两份文件都解不
/// 开**。这与 DPAPI 换个 Windows 账户解不开是同一类特性，不是缺陷；界面会按
/// 「请重新填一次」处理（见 `AppState._readCredentials`）。
class AndroidKeystoreSecretProtector implements SecretProtector {
  AndroidKeystoreSecretProtector._(this._key) : _random = Random.secure();

  /// 数据密钥。只活在进程内存里。
  final Uint8List _key;

  final Random _random;

  /// 存放「被 Keystore 包起来的 DEK」的文件名。
  ///
  /// 与 `config.json` **分开放**：密钥文件坏掉只该丢掉账号密码，不该让整份配置
  /// 都读不出来——`AppStore.load` 遇到坏 JSON 会返回空表，那是全丢。
  static const String wrappedKeyFileName = 'credentials.key';

  /// GCM 的 nonce 长度。96 位是 GCM 的标准长度，也是唯一不需要再做 GHASH 派生
  /// 的长度。
  static const int _nonceLength = 12;

  /// GCM 认证标签长度（位）。
  static const int _tagBits = 128;

  /// 数据密钥长度（字节）。原生侧生成的就是 32 字节；这里再卡一次，见 [_verified]。
  static const int _dekLength = 32;

  @override
  String get scheme => 'android-keystore';

  /// 创建时做过一次真实往返（见 [_verified]），所以这里可以如实为 true。
  @override
  bool get isSecure => true;

  @override
  String get description => '已用系统 Keystore 加密（Android Keystore）';

  /// 启动时调用一次：取回（或首次生成）数据密钥。
  ///
  /// 返回 null 表示**没法提供加密**，调用方应退回 [PlainSecretProtector] 并如实
  /// 告诉用户。三种情况：
  ///   * [directory] 为 null——没有可写目录，密钥存不住，下次启动就解不开今天写
  ///     下的密文。写不进去却宣称「已加密」，比不加密更坏。
  ///   * Keystore 或通道不可用（`generate` 返回 null）。
  ///   * 自检往返失败（[_verified]），说明这条链路眼下是坏的。
  static Future<AndroidKeystoreSecretProtector?> create({
    Directory? directory,
    KeystoreBackend backend = const MethodChannelKeystoreBackend(),
  }) async {
    if (directory == null) return null;
    final file = File(
      '${directory.path}${Platform.pathSeparator}$wrappedKeyFileName',
    );

    final existing = _readWrapped(file);
    if (existing != null) {
      final unwrapped = await _unwrapped(existing, backend);
      if (unwrapped != null) return _verified(unwrapped);
      // 解不开：多半是从云备份或另一台设备恢复过来的这两份文件，而 Keystore 里
      // 的包装密钥不随备份走。旧密文至此**已经不可能还原**——留着那个文件只会
      // 让人以为还有救，所以下面直接换成新密钥并覆盖它。用户侧看到的不是「静默
      // 丢密码」：凭据解不出来时 `AppState` 会把这份配置还原成「待补填账号密码」，
      // 配置页有入口，连接前也会明确提示。
      debugPrint('凭据密钥解不开（可能来自另一台设备），改用新密钥：${file.path}');
    }

    final generated = await _generate(backend);
    if (generated == null) return null;
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(generated.wrapped, flush: true);
    } on Object catch (e) {
      debugPrint('凭据密钥写入失败：$e');
      return null;
    }
    return _verified(base64Decode(generated.key));
  }

  /// 读那个文件。读不出来（不存在、权限、内容被截断）一律当作「没有」。
  static String? _readWrapped(File file) {
    try {
      if (!file.existsSync()) return null;
      final text = file.readAsStringSync().trim();
      return text.isEmpty ? null : text;
    } on Object catch (e) {
      debugPrint('凭据密钥读取失败：$e');
      return null;
    }
  }

  /// 问 Keystore 要一把新的数据密钥；任何异常都退化成 null。
  static Future<({String wrapped, String key})?> _generate(
    KeystoreBackend backend,
  ) async {
    try {
      return await backend.generate();
    } on Object catch (e) {
      debugPrint('生成凭据密钥失败：$e');
      return null;
    }
  }

  /// 解包并校验密钥长度。GCM 只认 128 / 192 / 256 位，长度不对宁可当没拿到。
  static Future<Uint8List?> _unwrapped(
    String wrapped,
    KeystoreBackend backend,
  ) async {
    final String? key;
    try {
      key = await backend.unwrap(wrapped);
    } on Object catch (e) {
      debugPrint('解开凭据密钥失败：$e');
      return null;
    }
    if (key == null) return null;
    try {
      return base64Decode(key);
    } on FormatException {
      return null;
    }
  }

  /// 用一次真实往返确认这把密钥**眼下**确实能用，长度也得对。
  ///
  /// 与 [LinuxSecretProtector.tryCreate] 同一个理由：不能假设「拿到了密钥」就等于
  /// 「加密可用」。`isSecure` 只在这条往返真的走通时才为 true。长度在这里卡住而
  /// 不是各写一遍：**两条来源**（首次生成 / 解包文件）都必须过这一关，任何一条
  /// 绕过去都会让「同一份密文换个来源就解不开」变成可能。
  static AndroidKeystoreSecretProtector? _verified(Uint8List key) {
    if (key.length != _dekLength) {
      debugPrint('凭据密钥长度不对（${key.length} 字节），当作没拿到');
      return null;
    }
    try {
      final protector = AndroidKeystoreSecretProtector._(key);
      final probe = 'xvpn-selftest-${DateTime.now().microsecondsSinceEpoch}';
      if (protector.unprotect(protector.protect(probe)) != probe) return null;
      return protector;
    } on Object catch (e) {
      debugPrint('凭据加密自检失败：$e');
      return null;
    }
  }

  @override
  String protect(String plaintext) {
    final nonce = _nonce();
    final sealed = _gcm(
      encrypt: true,
      nonce: nonce,
      input: Uint8List.fromList(utf8.encode(plaintext)),
    );
    final out = BytesBuilder(copy: false)
      ..add(nonce)
      ..add(sealed);
    return base64Encode(out.takeBytes());
  }

  /// 每次加密一把新的随机 nonce。
  ///
  /// GCM 下 nonce **绝不能在同一把密钥下重复**，重复会直接泄漏两次明文的异或，
  /// 并让认证失去意义。逐字节取 [_random]（`Random.secure()`，安卓上落到
  /// `/dev/urandom`）：96 位随机 nonce 在同一个密钥下重复的概率可以忽略，而
  /// 这里每次加密最多两三条凭据，量级上远够。
  Uint8List _nonce() {
    final nonce = Uint8List(_nonceLength);
    for (var i = 0; i < _nonceLength; i++) {
      nonce[i] = _random.nextInt(256);
    }
    return nonce;
  }

  @override
  String? unprotect(String payload) {
    final Uint8List bytes;
    try {
      bytes = base64Decode(payload);
    } on FormatException {
      return null;
    }
    // 短于 nonce + 标签的密文不可能出自 [protect]。
    if (bytes.length < _nonceLength + _tagBits ~/ 8) return null;
    final nonce = bytes.sublist(0, _nonceLength);
    try {
      final clear = _gcm(
        encrypt: false,
        nonce: nonce,
        input: Uint8List.sublistView(bytes, _nonceLength),
      );
      return utf8.decode(clear);
    } on InvalidCipherTextException {
      // 认证失败：密文被改过，或者这不是这把密钥加密的。与 DPAPI 解不开一样，
      // 交给调用方按「请重新填一次」处理。
      return null;
    } on FormatException {
      // 解出来不是合法 UTF-8：同上。
      return null;
    }
  }

  /// AES-256-GCM。
  ///
  /// 走纯 Dart 而不是把每次加解密都甩给原生：只有「解开 DEK」那一次必须问
  /// Keystore，之后的每一次都要是同步的（理由见类注释）。GCM 自带认证，因此
  /// 不需要再单独做一个 MAC。
  Uint8List _gcm({
    required bool encrypt,
    required Uint8List nonce,
    required Uint8List input,
  }) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        encrypt,
        AEADParameters(KeyParameter(_key), _tagBits, nonce, Uint8List(0)),
      );
    return cipher.process(input);
  }
}

// ---------------------------------------------------------------- 兜底方案

/// 不加密的兜底方案。
///
/// 它存在的意义是**保持行为诚实**：在没有可用系统凭据库的地方（Linux 上钥匙串
/// 不可用、安卓上 Keystore 或可写目录拿不到时），密码只能原样落盘。与其写一个
/// 自制的异或/固定密钥混淆来制造「已加密」的错觉，不如明确地不加密，并让界面
/// 把这件事告诉用户。
class PlainSecretProtector implements SecretProtector {
  const PlainSecretProtector({this.note});

  /// 平台特定的说明。Linux 上必须说清缺什么（`secret-tool`），
  /// 而不是笼统的「平台尚未接入」——那在 Linux 上并不准确。
  final String? note;

  @override
  String get scheme => 'plain';

  @override
  bool get isSecure => false;

  @override
  String get description => note ?? '未加密（当前平台尚未接入系统凭据库）';

  @override
  String protect(String plaintext) => plaintext;

  @override
  String? unprotect(String payload) => payload;
}
