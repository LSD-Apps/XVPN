import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// 账号密码的落盘保护。
///
/// 存在这一层的理由很具体：OpenVPN 的 `auth-user-pass` 配置必须带着账号密码
/// 才能连上，而这份密码要跟着配置一起落盘。直接写进 `config.json` 意味着任何
/// 读得到这个文件的人（同机的其它账户、备份、云同步、误发的日志）都拿得到
/// 明文密码。
///
/// 两个实现：
///   * [DpapiSecretProtector]：Windows 上用系统 DPAPI，密钥由当前 Windows
///     账户派生。换个账户或换台机器都解不开——这是它的**特性**而不是缺陷。
///   * [LinuxSecretProtector]：Linux 上用 Secret Service（libsecret 管理的
///     系统钥匙串）。落盘的是一个不透明的 key，密码本身存在钥匙串里。
///   * [PlainSecretProtector]：没有系统凭据库可用的平台上的兜底。它不加密，
///     并且 [isSecure] 会如实返回 false，界面据此提示用户，而不是假装已经
///     保护好了。
///
/// 落盘时会把 [scheme] 一起写下来，因此将来接入更好的方案（例如安卓
/// Keystore）时，旧数据仍然读得出来：按记录里的 scheme 选择还原方式。
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
              '--label "XVPN 凭据" service $_service account "\$1"',
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

// ---------------------------------------------------------------- 兜底方案

/// 不加密的兜底方案。
///
/// 它存在的意义是**保持行为诚实**：在没有可用系统凭据库的平台上（安卓的
/// Keystore 尚未接入；Linux 上钥匙串不可用时），密码只能原样落盘。与其写一个
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
