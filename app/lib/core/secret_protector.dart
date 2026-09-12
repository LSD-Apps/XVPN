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
  static SecretProtector forPlatform() {
    if (Platform.isWindows) {
      final dpapi = DpapiSecretProtector.tryCreate();
      if (dpapi != null) return dpapi;
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

// ---------------------------------------------------------------- 兜底方案

/// 不加密的兜底方案。
///
/// 它存在的意义是**保持行为诚实**：在还没有系统凭据库接入的平台上（目前是
/// 安卓，Keystore 尚未接），密码只能原样落盘。与其写一个自制的异或/固定密钥
/// 混淆来制造「已加密」的错觉，不如明确地不加密，并让界面把这件事告诉用户。
class PlainSecretProtector implements SecretProtector {
  const PlainSecretProtector();

  @override
  String get scheme => 'plain';

  @override
  bool get isSecure => false;

  @override
  String get description => '未加密（当前平台尚未接入系统凭据库）';

  @override
  String protect(String plaintext) => plaintext;

  @override
  String? unprotect(String payload) => payload;
}
