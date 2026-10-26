import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

/// Windows DPAPI（CryptProtectData / CryptUnprotectData），绑当前用户。
///
/// 落盘的敏感内容（密钥、输入法学习记录、输入法日志）都走这里：
/// 换台机器或换个账户就解不开——这是有意的。
class Dpapi {
  Dpapi._();

  static bool get supported => Platform.isWindows;

  /// 和 C++ 侧 Dpapi.cpp 用同一段熵，两边可以互解。
  static final Uint8List _entropy = _utf16le('HorseBox-v1');

  static final DynamicLibrary _crypt = DynamicLibrary.open('crypt32.dll');
  static final DynamicLibrary _kern = DynamicLibrary.open('kernel32.dll');
  static final DynamicLibrary _crt = DynamicLibrary.open('msvcrt.dll');

  static final _protect = _crypt.lookupFunction<
      Int32 Function(Pointer<_Blob>, Pointer<Uint16>, Pointer<_Blob>, Pointer<Void>,
          Pointer<Void>, Uint32, Pointer<_Blob>),
      int Function(Pointer<_Blob>, Pointer<Uint16>, Pointer<_Blob>, Pointer<Void>,
          Pointer<Void>, int, Pointer<_Blob>)>('CryptProtectData');

  static final _unprotect = _crypt.lookupFunction<
      Int32 Function(Pointer<_Blob>, Pointer<Void>, Pointer<_Blob>, Pointer<Void>,
          Pointer<Void>, Uint32, Pointer<_Blob>),
      int Function(Pointer<_Blob>, Pointer<Void>, Pointer<_Blob>, Pointer<Void>,
          Pointer<Void>, int, Pointer<_Blob>)>('CryptUnprotectData');

  static final _localFree = _kern
      .lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>(
          'LocalFree');

  static final _malloc = _crt
      .lookupFunction<Pointer<Uint8> Function(IntPtr), Pointer<Uint8> Function(int)>('malloc');

  static final _free =
      _crt.lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>('free');

  /// 加密失败返回 null。调用方必须当"不能落盘"处理，绝不能退回明文。
  static Uint8List? protect(List<int> data) {
    if (!supported || data.isEmpty) return null;
    return _run(data, (blob, entropy, out) => _protect(blob, nullptr, entropy, nullptr, nullptr, 0x1, out));
  }

  static Uint8List? unprotect(List<int> data) {
    if (!supported || data.isEmpty) return null;
    return _run(data, (blob, entropy, out) => _unprotect(blob, nullptr, entropy, nullptr, nullptr, 0x1, out));
  }

  static Uint8List? _run(
    List<int> data,
    int Function(Pointer<_Blob>, Pointer<_Blob>, Pointer<_Blob>) call,
  ) {
    final size = sizeOf<_Blob>();
    final inBytes = _malloc(data.length);
    final inBlob = _malloc(size).cast<_Blob>();
    final entBytes = _malloc(_entropy.length);
    final entBlob = _malloc(size).cast<_Blob>();
    final outBlob = _malloc(size).cast<_Blob>();
    try {
      inBytes.asTypedList(data.length).setAll(0, data);
      inBlob.ref.cbData = data.length;
      inBlob.ref.pbData = inBytes;

      entBytes.asTypedList(_entropy.length).setAll(0, _entropy);
      entBlob.ref.cbData = _entropy.length;
      entBlob.ref.pbData = entBytes;

      outBlob.ref.cbData = 0;
      outBlob.ref.pbData = nullptr;

      if (call(inBlob, entBlob, outBlob) == 0) return null;
      if (outBlob.ref.pbData == nullptr) return null;
      final result = Uint8List.fromList(outBlob.ref.pbData.asTypedList(outBlob.ref.cbData));
      _localFree(outBlob.ref.pbData.cast());
      return result;
    } catch (_) {
      return null;
    } finally {
      _free(inBytes);
      _free(inBlob.cast());
      _free(entBytes);
      _free(entBlob.cast());
      _free(outBlob.cast());
    }
  }

  static Uint8List _utf16le(String s) {
    final out = Uint8List(s.length * 2);
    for (var i = 0; i < s.length; i++) {
      final code = s.codeUnitAt(i);
      out[i * 2] = code & 0xFF;
      out[i * 2 + 1] = (code >> 8) & 0xFF;
    }
    return out;
  }
}

final class _Blob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}
