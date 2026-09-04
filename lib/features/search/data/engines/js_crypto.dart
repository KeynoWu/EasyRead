import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:easy_quickjs/quickjs.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:html/parser.dart' as parser;
import 'json_path.dart';
import 'rule_engine.dart';
import 'js_rule_executor.dart';

/// JS 桥加解密/哈希/时间戳工具（java.* crypto 桥的 Dart 实现）。
/// 纯工具类：不持有引擎状态，输入输出显式；由 [JsRuleExecutor] 与
/// 模板缓存（_TemplateCaches/_JsCryptoCaches）调用。
class JsCrypto {
  static String uuid4() {
    final random = Random();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  static Future<List<TimeArg>> readTimeArgs(JsEngine engine) async {
    try {
      final decoded = jsonDecode(
        (await engine.eval('JSON.stringify(__time)').timeout(JsRuleExecutor.evalTimeout))
            .value,
      );
      return [
        for (final raw in decoded as List)
          TimeArg(
            timestamp: raw is List && raw.isNotEmpty ? raw[0].toString() : '0',
            format: raw is List && raw.length > 1 ? raw[1].toString() : '',
            shift: raw is List && raw.length > 2 ? raw[2].toString() : '0',
          ),
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<List<HmacArg>> readHmacArgs(
    JsEngine engine,
    String name,
  ) async {
    try {
      final decoded = jsonDecode(
        (await engine.eval('JSON.stringify($name)').timeout(JsRuleExecutor.evalTimeout)).value,
      );
      return [
        for (final raw in decoded as List)
          HmacArg(
            data: raw is List && raw.isNotEmpty ? raw[0].toString() : '',
            algorithm: raw is List && raw.length > 1 ? raw[1].toString() : '',
            key: raw is List && raw.length > 2 ? raw[2].toString() : '',
          ),
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<List<AesArg>> readAesArgs(
    JsEngine engine,
    String name,
  ) async {
    try {
      final decoded = jsonDecode(
        (await engine.eval('JSON.stringify($name)').timeout(JsRuleExecutor.evalTimeout)).value,
      );
      return [
        for (final raw in decoded as List)
          AesArg(
            data: raw is List && raw.isNotEmpty ? raw[0].toString() : '',
            key: raw is List && raw.length > 1 ? raw[1].toString() : '',
            transformation: raw is List && raw.length > 2
                ? raw[2].toString()
                : '',
            iv: raw is List && raw.length > 3 ? raw[3].toString() : '',
          ),
      ];
    } catch (_) {
      return [];
    }
  }

  static String hmacHex(HmacArg arg) {
    try {
      final hmac = Hmac(hashForAlgorithm(arg.algorithm), utf8.encode(arg.key));
      return hmac.convert(utf8.encode(arg.data)).toString();
    } catch (_) {
      return '';
    }
  }

  static String hmacBase64(HmacArg arg) {
    try {
      final hmac = Hmac(hashForAlgorithm(arg.algorithm), utf8.encode(arg.key));
      return base64Encode(hmac.convert(utf8.encode(arg.data)).bytes);
    } catch (_) {
      return '';
    }
  }

  static Hash hashForAlgorithm(String algorithm) {
    final normalized = algorithm
        .toUpperCase()
        .replaceAll('HMAC', '')
        .replaceAll('-', '');
    switch (normalized) {
      case 'MD5':
        return md5;
      case 'SHA1':
        return sha1;
      case 'SHA256':
        return sha256;
      case 'SHA512':
        return sha512;
      default:
        return sha256;
    }
  }

  static Future<List<DigestArg>> readDigestArgs(
    JsEngine engine,
    String name,
  ) async {
    try {
      final decoded = jsonDecode(
        (await engine.eval('JSON.stringify($name)').timeout(JsRuleExecutor.evalTimeout)).value,
      );
      return [
        for (final raw in decoded as List)
          DigestArg(
            data: raw is List && raw.isNotEmpty ? raw[0].toString() : '',
            algorithm: raw is List && raw.length > 1 ? raw[1].toString() : '',
          ),
      ];
    } catch (_) {
      return [];
    }
  }

  static String digestHex(DigestArg arg) {
    try {
      return hashForAlgorithm(
        arg.algorithm,
      ).convert(utf8.encode(arg.data)).toString();
    } catch (_) {
      return '';
    }
  }

  static String aesDecodeToString(AesArg arg, {required bool base64Input}) {
    try {
      final transformation = arg.transformation.toUpperCase();
      final useCbc = transformation.contains('/CBC/');
      final key = encrypt.Key(aesKeyBytes(arg.key));
      final iv = encrypt.IV(aesIvBytes(arg.iv, useCbc: useCbc));
      final mode = useCbc ? encrypt.AESMode.cbc : encrypt.AESMode.ecb;
      final encrypter = encrypt.Encrypter(
        encrypt.AES(key, mode: mode, padding: 'PKCS7'),
      );
      final data = base64Input
          ? base64Decode(arg.data)
          : decodeAesData(arg.data);
      final decrypted = encrypter.decryptBytes(
        encrypt.Encrypted(data),
        iv: useCbc ? iv : null,
      );
      return utf8.decode(decrypted, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  static String aesEncodeToBase64(AesArg arg) {
    try {
      final transformation = arg.transformation.toUpperCase();
      final useCbc = transformation.contains('/CBC/');
      final key = encrypt.Key(aesKeyBytes(arg.key));
      final iv = encrypt.IV(aesIvBytes(arg.iv, useCbc: useCbc));
      final mode = useCbc ? encrypt.AESMode.cbc : encrypt.AESMode.ecb;
      final encrypter = encrypt.Encrypter(
        encrypt.AES(key, mode: mode, padding: 'PKCS7'),
      );
      final encrypted = encrypter.encryptBytes(
        Uint8List.fromList(utf8.encode(arg.data)),
        iv: useCbc ? iv : null,
      );
      return base64Encode(encrypted.bytes);
    } catch (_) {
      return '';
    }
  }

  static Uint8List aesKeyBytes(String key) {
    final bytes = utf8.encode(key);
    if (bytes.length == 16 || bytes.length == 24 || bytes.length == 32) {
      return Uint8List.fromList(bytes);
    }
    return Uint8List.fromList(md5.convert(utf8.encode(key)).bytes);
  }

  static Uint8List aesIvBytes(String iv, {required bool useCbc}) {
    if (!useCbc) return Uint8List(0);
    final bytes = utf8.encode(iv);
    if (bytes.length == 16) return Uint8List.fromList(bytes);
    if (bytes.length > 16) return Uint8List.fromList(bytes.sublist(0, 16));
    return Uint8List.fromList(md5.convert(utf8.encode(iv)).bytes);
  }

  /// 对齐 hutool SecureUtil.decode（Legado decrypt/decryptStr 的实际解码）：
  /// 纯十六进制串按 hex 解码（任意偶数长度），否则按 base64 解码。
  static Uint8List decodeAesData(String data) {
    final trimmed = data.trim();
    if (trimmed.length.isEven &&
        RegExp(r'^[0-9a-fA-F]+$').hasMatch(trimmed)) {
      final bytes = <int>[];
      for (var i = 0; i + 1 < trimmed.length; i += 2) {
        bytes.add(int.parse(trimmed.substring(i, i + 2), radix: 16));
      }
      return Uint8List.fromList(bytes);
    }
    return Uint8List.fromList(base64Decode(trimmed));
  }

  static Future<List<SymmetricArg>> readSymmetricArgs(
    JsEngine engine,
    String name,
  ) async {
    try {
      final decoded = jsonDecode(
        (await engine.eval('JSON.stringify($name)').timeout(JsRuleExecutor.evalTimeout)).value,
      );
      return [
        for (final raw in decoded as List)
          SymmetricArg(
            id: raw is List && raw.isNotEmpty
                ? int.tryParse(raw[0].toString()) ?? 0
                : 0,
            transformation: raw is List && raw.length > 1
                ? raw[1].toString()
                : '',
            key: raw is List && raw.length > 2 ? raw[2].toString() : '',
            iv: raw is List && raw.length > 3 ? raw[3].toString() : '',
          ),
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<List<SymmetricOp>> readSymmetricOps(
    JsEngine engine,
    String name,
  ) async {
    try {
      final decoded = jsonDecode(
        (await engine.eval('JSON.stringify($name)').timeout(JsRuleExecutor.evalTimeout)).value,
      );
      return [
        for (final raw in decoded as List)
          SymmetricOp(
            id: raw is List && raw.isNotEmpty
                ? int.tryParse(raw[0].toString()) ?? 0
                : 0,
            data: raw is List && raw.length > 1 ? raw[1].toString() : '',
          ),
      ];
    } catch (_) {
      return [];
    }
  }

  static String symmetricDecryptToString(SymmetricArg arg, String data) {
    try {
      return utf8.decode(
        symmetricDecryptToBytes(arg, data),
        allowMalformed: true,
      );
    } catch (_) {
      return '';
    }
  }

  static Uint8List symmetricDecryptToBytes(SymmetricArg arg, String data) {
    return symmetricProcess(arg, decodeAesData(data), encrypting: false);
  }

  static Uint8List symmetricEncryptToBytes(SymmetricArg arg, String data) {
    return symmetricProcess(
      arg,
      Uint8List.fromList(utf8.encode(data)),
      encrypting: true,
    );
  }

  static final RegExp _streamModePattern = RegExp(r'^(CFB|OFB)([0-9]+)?$');

  /// 对称加解密主流程。对齐 Legado（hutool SymmetricCrypto）语义：transformation
  /// 直通 JCE——算法段可省 mode/padding（JCE 缺省 ECB+PKCS5）；ECB/CBC 支持
  /// PKCS5/PKCS7 与 NoPadding；CTR/SIC、CFB-N、OFB-N 为流式（任意长度、尾部可
  /// 不齐块）；GCM 仅 AES/NoPadding（SunJCE 缺省 tag=128bit，密文尾随 tag）。
  /// 不支持/参数非法时返回空数组。
  static Uint8List symmetricProcess(
    SymmetricArg arg,
    Uint8List input, {
    required bool encrypting,
  }) {
    try {
      final segments = arg.transformation.toUpperCase().trim().split('/');
      final algorithm = segments[0].trim();
      final mode = segments.length > 1 && segments[1].trim().isNotEmpty
          ? segments[1].trim()
          : 'ECB';
      // JCE 省略 padding 段时默认 PKCS5Padding（块长 16/8 下等价 PKCS7）。
      final padding = segments.length > 2 && segments[2].trim().isNotEmpty
          ? segments[2].trim()
          : 'PKCS5PADDING';
      final isNoPadding = padding == 'NOPADDING';
      String blockName;
      var blockSize = 0;
      if (algorithm == 'AES') {
        blockName = 'AES';
        blockSize = 16;
      } else if (algorithm == 'DESEDE' || algorithm == '3DES') {
        blockName = 'DESede';
        blockSize = 8;
      } else {
        // pointycastle 未内置单 DES，保持与旧桥一致的“不支持”行为。
        return Uint8List(0);
      }
      final key = symmetricKeyBytes(algorithm, arg.key);

      // GCM：JCE 仅支持 AES/GCM/NoPadding；IvParameterSpec 原样作 nonce
      // （不截断不散列），缺省 tag 128bit——加密封文尾随 tag，解密校验失败即错。
      if (mode == 'GCM') {
        if (algorithm != 'AES' || !isNoPadding) return Uint8List(0);
        final nonce = Uint8List.fromList(utf8.encode(arg.iv));
        if (nonce.isEmpty) return Uint8List(0);
        final cipher = pc.BlockCipher('AES/GCM');
        cipher.init(
          encrypting,
          pc.AEADParameters(pc.KeyParameter(key), 128, nonce, Uint8List(0)),
        );
        return cipher.process(input);
      }

      // CTR/SIC：pointycastle 流式实现（整计数器大端自增，对齐 JCE CTR）。
      if (mode == 'CTR' || mode == 'SIC') {
        final iv = symmetricIvBytes(algorithm, arg.iv);
        final cipher = pc.StreamCipher('$blockName/CTR');
        cipher.init(encrypting, pc.ParametersWithIV(pc.KeyParameter(key), iv));
        return _withOptionalPkcs7(
          cipher.process,
          input,
          encrypting: encrypting,
          blockSize: blockSize,
          isNoPadding: isNoPadding,
        );
      }

      // CFB/OFB（可带反馈位数，缺省=块长）：pointycastle 块模式只整块推进，
      // 这里按 JCE 流式语义手工处理，保证尾部不齐块时输出与 JCE 一致。
      final streamMode = _streamModePattern.firstMatch(mode);
      if (streamMode != null) {
        final bits = streamMode.group(2) != null
            ? int.tryParse(streamMode.group(2)!)
            : null;
        if (bits != null && bits % 8 != 0) return Uint8List(0);
        final feedback = (bits ?? blockSize * 8) ~/ 8;
        if (feedback < 1 || feedback > blockSize) return Uint8List(0);
        final core = pc.BlockCipher(blockName);
        core.init(true, pc.KeyParameter(key));
        final iv = symmetricIvBytes(algorithm, arg.iv);
        return _withOptionalPkcs7(
          (body) => streamMode.group(1) == 'CFB'
              ? _cfbProcessBytes(core, iv, body, feedback, encrypting)
              : _ofbProcessBytes(core, iv, body, feedback),
          input,
          encrypting: encrypting,
          blockSize: blockSize,
          isNoPadding: isNoPadding,
        );
      }

      // ECB/CBC：保留原桥行为——带 padding 走 PaddedBlockCipher(PKCS7)。
      pc.CipherParameters params = mode == 'CBC'
          ? pc.ParametersWithIV(
              pc.KeyParameter(key),
              symmetricIvBytes(algorithm, arg.iv),
            )
          : pc.KeyParameter(key);
      if (isNoPadding) {
        if (input.length % blockSize != 0) return Uint8List(0);
        final cipher = pc.BlockCipher('$blockName/$mode');
        cipher.init(encrypting, params);
        return _processWholeBlocks(cipher, input);
      }
      final cipher = pc.PaddedBlockCipher('$blockName/$mode/PKCS7');
      cipher.init(
        encrypting,
        pc.PaddedBlockCipherParameters<
          pc.CipherParameters?,
          pc.CipherParameters?
        >(params, null),
      );
      return cipher.process(input);
    } catch (_) {
      return Uint8List(0);
    }
  }

  /// 流式模式的可选 PKCS7 padding 包装：加密先填充，解密后剥离
  /// （对齐 JCE：CTR/CFB/OFB + PKCS5Padding 与 NoPadding 两种形态）。
  static Uint8List _withOptionalPkcs7(
    Uint8List Function(Uint8List body) process,
    Uint8List input, {
    required bool encrypting,
    required int blockSize,
    required bool isNoPadding,
  }) {
    if (isNoPadding) return process(input);
    if (encrypting) return process(_pkcs7Pad(input, blockSize));
    return _pkcs7Unpad(process(input), blockSize);
  }

  /// 逐整块处理（NoPadding 的 ECB/CBC：调用前须保证长度为块长整数倍）。
  static Uint8List _processWholeBlocks(pc.BlockCipher cipher, Uint8List input) {
    final blockSize = cipher.blockSize;
    final out = Uint8List(input.length);
    var offset = 0;
    while (offset + blockSize <= input.length) {
      offset += cipher.processBlock(input, offset, out, offset);
    }
    return out;
  }

  /// CFB-N 流式处理：密文反馈进移位寄存器；尾部不足一个反馈单元时
  /// 直接取密钥流前缀异或（与 JCE/SunJCE 输出一致）。
  static Uint8List _cfbProcessBytes(
    pc.BlockCipher core,
    Uint8List iv,
    Uint8List input,
    int feedback,
    bool encrypting,
  ) {
    final blockSize = core.blockSize;
    final register = Uint8List.fromList(iv);
    final keystream = Uint8List(blockSize);
    final out = Uint8List(input.length);
    var offset = 0;
    while (offset < input.length) {
      core.processBlock(register, 0, keystream, 0);
      final chunk =
          feedback < input.length - offset ? feedback : input.length - offset;
      for (var i = 0; i < chunk; i++) {
        out[offset + i] = input[offset + i] ^ keystream[i];
      }
      if (chunk == feedback) {
        final feed = encrypting ? out : input;
        register.setRange(0, blockSize - feedback, register.sublist(feedback));
        register.setRange(blockSize - feedback, blockSize, feed, offset);
      }
      offset += chunk;
    }
    return out;
  }

  /// OFB-N 流式处理：密钥流独立于数据（寄存器反馈密钥流自身），
  /// 加解密同一实现；尾部不足一个反馈单元时取密钥流前缀异或。
  static Uint8List _ofbProcessBytes(
    pc.BlockCipher core,
    Uint8List iv,
    Uint8List input,
    int feedback,
  ) {
    final blockSize = core.blockSize;
    final register = Uint8List.fromList(iv);
    final keystream = Uint8List(blockSize);
    final out = Uint8List(input.length);
    var offset = 0;
    while (offset < input.length) {
      core.processBlock(register, 0, keystream, 0);
      final chunk =
          feedback < input.length - offset ? feedback : input.length - offset;
      for (var i = 0; i < chunk; i++) {
        out[offset + i] = input[offset + i] ^ keystream[i];
      }
      if (chunk == feedback) {
        register.setRange(0, blockSize - feedback, register.sublist(feedback));
        register.setRange(blockSize - feedback, blockSize, keystream, 0);
      }
      offset += chunk;
    }
    return out;
  }

  static Uint8List _pkcs7Pad(Uint8List input, int blockSize) {
    final pad = blockSize - input.length % blockSize;
    final out = Uint8List(input.length + pad);
    out.setAll(0, input);
    out.fillRange(input.length, out.length, pad);
    return out;
  }

  static Uint8List _pkcs7Unpad(Uint8List input, int blockSize) {
    if (input.isEmpty || input.length % blockSize != 0) {
      throw const FormatException('invalid pkcs7 length');
    }
    final pad = input.last;
    if (pad < 1 || pad > blockSize) {
      throw const FormatException('invalid pkcs7 padding');
    }
    for (var i = input.length - pad; i < input.length; i++) {
      if (input[i] != pad) {
        throw const FormatException('invalid pkcs7 padding');
      }
    }
    return Uint8List.fromList(input.sublist(0, input.length - pad));
  }

  static Uint8List symmetricKeyBytes(String algorithm, String key) {
    if (algorithm == 'AES') return aesKeyBytes(key);
    final bytes = utf8.encode(key);
    if (bytes.length == 24) return Uint8List.fromList(bytes);
    if (bytes.length > 24) {
      return Uint8List.fromList(bytes.sublist(0, 24));
    }
    if (bytes.length == 16) {
      return Uint8List.fromList([...bytes, ...bytes.sublist(0, 8)]);
    }
    if (bytes.length == 8) {
      return Uint8List.fromList([...bytes, ...bytes, ...bytes]);
    }
    final digest = md5.convert(utf8.encode(key)).bytes;
    return Uint8List.fromList([...digest, ...digest.sublist(0, 8)]);
  }

  static Uint8List symmetricIvBytes(String algorithm, String iv) {
    if (algorithm == 'AES') return aesIvBytes(iv, useCbc: true);
    final bytes = utf8.encode(iv);
    if (bytes.length == 8) return Uint8List.fromList(bytes);
    if (bytes.length > 8) {
      return Uint8List.fromList(bytes.sublist(0, 8));
    }
    final digest = md5.convert(utf8.encode(iv)).bytes;
    return Uint8List.fromList(digest.sublist(0, 8));
  }

  static String bytesToHex(Uint8List bytes) {
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  static String queryJsonPath(Map<String, dynamic>? json, String path) {
    if (json == null || path.isEmpty) return '';
    var normalized = path;
    if (!normalized.startsWith(r'$') && !normalized.startsWith('.')) {
      normalized = '.$normalized';
    }
    final values = JsonPathEngine.instance.query(json, normalized);
    if (values.isEmpty) return '';
    final value = values.first;
    if (value == null) return '';
    if (value is String) return value;
    return jsonEncode(value);
  }

  static String queryHtmlPath(String html, String path) {
    if (html.isEmpty || path.isEmpty) return '';
    if (path == 'url') return '';
    try {
      final elements = RuleEngine.queryIn(parser.parse(html), path);
      return elements.isEmpty
          ? ''
          : (RuleEngine.valueOf(elements.first, null) ?? '');
    } catch (_) {
      return '';
    }
  }

  static String hexEncode(String value) {
    return utf8
        .encode(value)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static String hexDecode(String hex) {
    try {
      final bytes = <int>[];
      for (var i = 0; i + 1 < hex.length; i += 2) {
        bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
      }
      return utf8.decode(bytes);
    } catch (_) {
      return '';
    }
  }

  static String base64DecodeToString(String value) {
    try {
      return utf8.decode(base64Decode(value));
    } catch (_) {
      return '';
    }
  }

  static List<int> base64DecodeToBytes(String value) {
    try {
      return base64Decode(value);
    } catch (_) {
      return [];
    }
  }

  static String formatTimestamp(TimeArg arg) {
    final timestamp = int.tryParse(arg.timestamp) ?? 0;
    final shift = int.tryParse(arg.shift) ?? 0;
    final date = DateTime.fromMillisecondsSinceEpoch(
      timestamp,
      isUtc: shift != 0,
    ).add(Duration(hours: shift));
    // Legado 默认格式 AppConst.dateFormat = "yyyy/MM/dd HH:mm"（本地时区，
    // JsExtensions.kt:504 timeFormat(time) 1 参调用），非 "yyyy-MM-dd HH:mm:ss"
    final pattern = arg.format.isEmpty ? 'yyyy/MM/dd HH:mm' : arg.format;
    return pattern
        .replaceAll('yyyy', pad(date.year, 4))
        .replaceAll('MM', pad(date.month, 2))
        .replaceAll('dd', pad(date.day, 2))
        .replaceAll('HH', pad(date.hour, 2))
        .replaceAll('mm', pad(date.minute, 2))
        .replaceAll('ss', pad(date.second, 2));
  }

  static String pad(int value, int width) =>
      value.toString().padLeft(width, '0');
}

class TimeArg {
  final String timestamp;
  final String format;
  final String shift;

  const TimeArg({
    required this.timestamp,
    required this.format,
    required this.shift,
  });

  String get key => '$timestamp|$format|$shift';
}

class HmacArg {
  final String data;
  final String algorithm;
  final String key;

  const HmacArg({
    required this.data,
    required this.algorithm,
    required this.key,
  });

  String get cacheKey => '$data|$algorithm|$key';
}

class AesArg {
  final String data;
  final String key;
  final String transformation;
  final String iv;

  const AesArg({
    required this.data,
    required this.key,
    required this.transformation,
    required this.iv,
  });

  String get cacheKey => '$data|$key|$transformation|$iv';
}

class SymmetricArg {
  final int id;
  final String transformation;
  final String key;
  final String iv;

  const SymmetricArg({
    required this.id,
    required this.transformation,
    required this.key,
    required this.iv,
  });
}

class SymmetricOp {
  final int id;
  final String data;

  const SymmetricOp({required this.id, required this.data});
}

class DigestArg {
  final String data;
  final String algorithm;

  const DigestArg({required this.data, required this.algorithm});
}

