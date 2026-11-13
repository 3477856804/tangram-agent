import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// 微软 Edge TTS（readaloud）免费在线语音合成，即开源项目 edge-tts 的协议。
///
/// - 音色列表：REST GET voices/list（trusted client token 为公开固定值）。
/// - 合成：WebSocket wss://…/readaloud/edge/v1，携带 Sec-MS-GEC 校验令牌。
///   注意：微软已于 2025 年切换 DRM v2 —— 旧版「大写 hex(SHA256(FILETIME 整秒
///   + token)) + Sec-MS-GEC-Version=1-131.x」握手实测返回 403（官方 PyPI
///   edge-tts 7.2.7 同样 403）；现行 edge-tts master 实现为
///   「CS64-自定义SHA256 双段大写 hex + 2-143.0.3650.75」，本文件按 master
///   逐字段移植（见 [_EdgeDrm]），实测沙箱内可真实出音。
/// - 消息：speech.config + ssml 两条文本帧；收二进制帧（2 字节大端头长 +
///   头文本 + mp3 分片），拼成完整 mp3（audio-24khz-48kbitrate-mono-mp3）。
///
/// 纯 Dart（dart:io），不依赖 Flutter，可脱离 UI 用 `dart run` 直接验证。
class EdgeTts {
  EdgeTts._();

  static const String trustedClientToken =
      '6A5AA1D4EAFF4E9FB37E23D68491D6F4';

  static const String _base =
      'speech.platform.bing.com/consumer/speech/synthesize/readaloud';
  static const String _voicesUrl =
      'https://$_base/voices/list?trustedclienttoken=$trustedClientToken';
  static const String _wssUrl =
      'wss://$_base/edge/v1?TrustedClientToken=$trustedClientToken';

  // 与 edge-tts master constants.py 一致的 Chromium 版本对。
  static const String _chromiumFullVersion = '143.0.3650.75';
  static const String _chromiumMajorVersion = '143';
  static const String _drmVersion = '2-$_chromiumFullVersion';
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/$_chromiumMajorVersion.0.0.0 '
      'Safari/537.36 Edg/$_chromiumMajorVersion.0.0.0';
  static const String _origin =
      'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold';

  /// 拉取音色列表，只保留中文（zh-CN）与英文（en-US）两组。
  /// 结果进程内缓存，重复打开音色表不再走网络。
  static Future<List<EdgeTtsVoice>> fetchVoices() async {
    final List<EdgeTtsVoice>? cached = _voicesCache;
    if (cached != null) return cached;
    final HttpClient client = _newHttpClient();
    try {
      final HttpClientRequest req =
          await client.getUrl(Uri.parse(_voicesUrl));
      req.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
      final HttpClientResponse resp =
          await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode != HttpStatus.ok) {
        throw EdgeTtsException('音色列表 HTTP ${resp.statusCode}');
      }
      final Object? decoded =
          jsonDecode(await resp.transform(utf8.decoder).join());
      if (decoded is! List) throw EdgeTtsException('音色列表格式异常');
      final List<EdgeTtsVoice> voices = decoded
          .whereType<Map<dynamic, dynamic>>()
          .map((Map<dynamic, dynamic> e) =>
              EdgeTtsVoice.fromJson(e.cast<String, dynamic>()))
          .whereType<EdgeTtsVoice>()
          .toList();
      if (voices.isEmpty) throw EdgeTtsException('音色列表为空');
      _voicesCache = voices;
      return voices;
    } on EdgeTtsException {
      rethrow;
    } on Object catch (e) {
      throw EdgeTtsException('音色列表获取失败：$e');
    } finally {
      client.close(force: true);
    }
  }

  static List<EdgeTtsVoice>? _voicesCache;

  /// 生成 Sec-MS-GEC（DRM v2）令牌：当前 FILETIME 整 300 秒 ticks 拼接
  /// trusted token 后做「CS64 + 自定义 SHA-256」双摘要，格式
  /// `<16 hex CS64>-<64 hex SHA256>`，全部大写 hex。
  static String secMsGecToken() => _EdgeDrm.token(
      DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
      trustedClientToken);

  /// 合成一段文本，返回完整 mp3 字节（audio-24khz-48kbitrate-mono-mp3）。
  /// [voice] 为 ShortName（如 zh-CN-XiaoyiNeural），[text] 为待读文本。
  static Future<Uint8List> synthesizeMp3(
    String text, {
    required String voice,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    if (text.trim().isEmpty) throw EdgeTtsException('合成文本为空');
    final String connectionId = _randomHex(16);
    final String url = '$_wssUrl&ConnectionId=$connectionId'
        '&Sec-MS-GEC=${secMsGecToken()}'
        '&Sec-MS-GEC-Version=$_drmVersion';

    final HttpClient client = _newHttpClient()
      // WebSocket.connect 对 headers 是 add 语义：必须清掉 dart:io 默认
      // UA（"Dart/3.x (dart:io)"），否则与 Edge UA 拼成双值，微软 WAF 403。
      ..userAgent = null;
    WebSocket ws;
    try {
      ws = await WebSocket.connect(url, headers: <String, String>{
        HttpHeaders.userAgentHeader: _userAgent,
        HttpHeaders.acceptLanguageHeader: 'en-US,en;q=0.9',
        HttpHeaders.pragmaHeader: 'no-cache',
        HttpHeaders.cacheControlHeader: 'no-cache',
        'Origin': _origin,
        // edge-tts master: 每次连接随机 muid Cookie。
        HttpHeaders.cookieHeader: 'muid=${_randomHex(16).toUpperCase()};',
      }, customClient: client).timeout(timeout);
    } on TimeoutException {
      client.close(force: true);
      throw EdgeTtsException('连接 Edge TTS 超时');
    } on WebSocketException catch (e) {
      client.close(force: true);
      throw EdgeTtsException('握手失败：${e.message}');
    } on SocketException catch (e) {
      client.close(force: true);
      throw EdgeTtsException('网络错误：${e.osError?.message ?? e.message}');
    }

    final String timestamp = _edgeDateString(DateTime.now().toUtc());

    // 1) speech.config：固定文本头 + JSON 体（输出 mp3 24kHz）。
    ws.add('X-Timestamp:$timestamp\r\n'
        'Content-Type:application/json; charset=utf-8\r\n'
        'Path:speech.config\r\n\r\n'
        '{"context":{"synthesis":{"audio":{"metadataoptions":'
        '{"sentenceBoundaryEnabled":"true","wordBoundaryEnabled":"false"},'
        '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}\r\n');

    // 2) ssml 消息：文本头 + SSML 体（edge-tts mkssml 同款模板）。
    final String ssml = "<speak version='1.0' "
        "xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>"
        "<voice name='$voice'>"
        "<prosody pitch='+0Hz' rate='+0%' volume='+0%'>"
        '${_escapeXml(text)}'
        '</prosody></voice></speak>';
    ws.add('X-RequestId:${_randomHex(16)}\r\n'
        'Content-Type:application/ssml+xml\r\n'
        'X-Timestamp:${timestamp}Z\r\n' // 尾部多一个 Z：微软 Edge 的历史 bug，照抄
        'Path:ssml\r\n\r\n'
        '$ssml');

    final BytesBuilder audio = BytesBuilder(copy: false);
    final Completer<Uint8List> done = Completer<Uint8List>();
    late final StreamSubscription<Object?> sub;
    sub = ws.listen(
      (Object? event) {
        if (event is String) {
          if (event.contains('Path:turn.end') && !done.isCompleted) {
            done.complete(audio.toBytes());
          }
          return;
        }
        if (event is! List<int>) return;
        final Uint8List frame =
            event is Uint8List ? event : Uint8List.fromList(event);
        if (frame.length < 2) return;
        final int headerLen = (frame[0] << 8) | frame[1];
        if (frame.length < 2 + headerLen) return;
        final String header =
            String.fromCharCodes(frame.sublist(2, 2 + headerLen));
        // 只收 Path:audio 分片；跳过 Path:audio.metadata（句边界 JSON）。
        if (header.contains('Path:audio') &&
            !header.contains('Path:audio.metadata')) {
          audio.add(frame.sublist(2 + headerLen));
        }
      },
      onError: (Object e, StackTrace s) {
        if (!done.isCompleted) {
          done.completeError(EdgeTtsException('合成连接中断：$e'), s);
        }
      },
      cancelOnError: true,
    );

    try {
      final Uint8List bytes = await done.future.timeout(timeout);
      if (bytes.isEmpty) throw EdgeTtsException('未收到音频数据');
      return bytes;
    } on TimeoutException {
      throw EdgeTtsException('合成超时（${timeout.inSeconds}s）');
    } finally {
      await sub.cancel();
      await ws.close();
      client.close(force: true);
    }
  }

  /// 沙箱/桌面环境下尊重 HTTP(S)_PROXY，移动端无环境变量即直连。
  static HttpClient _newHttpClient() => HttpClient()
    ..findProxy = HttpClient.findProxyFromEnvironment
    ..connectionTimeout = const Duration(seconds: 10);

  static String _escapeXml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll("'", '&apos;');

  /// edge-tts date_to_string：JS 风格 UTC 时间戳。
  static String _edgeDateString(DateTime utc) {
    const List<String> days =
        ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const List<String> months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    String two(int v) => v.toString().padLeft(2, '0');
    return '${days[utc.weekday - 1]} ${months[utc.month - 1]} '
        '${two(utc.day)} ${utc.year} '
        '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} '
        'GMT+0000 (Coordinated Universal Time)';
  }

  static String _randomHex(int byteLen) {
    final Random rnd = Random.secure();
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < byteLen; i++) {
      sb.write(rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}

/// 合成 / 列表请求失败。message 面向用户如实展示。
class EdgeTtsException implements Exception {
  EdgeTtsException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 单个可选音色。
class EdgeTtsVoice {
  const EdgeTtsVoice({
    required this.shortName,
    required this.displayName,
    required this.gender,
    required this.locale,
  });

  /// 服务端 ShortName，如 zh-CN-XiaoyiNeural（合成与持久化用它）。
  final String shortName;

  /// 本地化展示名：中文音色用通译名（晓伊），英文音色用英文名（Ava）。
  final String displayName;

  /// Female / Male。
  final String gender;

  /// zh-CN / en-US。
  final String locale;

  bool get isFemale => gender == 'Female';
  bool get isChinese => locale == 'zh-CN';

  /// 服务端列表无 LocalName 字段，展示名由 ShortName 派生：
  /// zh-CN 命中内置通译名字典，其余从 FriendlyName 提取核心名。
  static EdgeTtsVoice? fromJson(Map<String, dynamic> m) {
    final String? shortName = m['ShortName'] as String?;
    final String? locale = m['Locale'] as String?;
    if (shortName == null || locale == null) return null;
    if (locale != 'zh-CN' && locale != 'en-US') return null;
    return EdgeTtsVoice(
      shortName: shortName,
      displayName: _displayNameOf(shortName, '${m['FriendlyName'] ?? ''}'),
      gender: (m['Gender'] ?? 'Female').toString(),
      locale: locale,
    );
  }

  static const Map<String, String> _zhNames = <String, String>{
    'zh-CN-XiaoxiaoNeural': '晓晓',
    'zh-CN-XiaoyiNeural': '晓伊',
    'zh-CN-XiaobeiNeural': '小北',
    'zh-CN-XiaochenNeural': '晓辰',
    'zh-CN-YunjianNeural': '云健',
    'zh-CN-YunxiNeural': '云希',
    'zh-CN-YunxiaNeural': '云夏',
    'zh-CN-YunyangNeural': '云扬',
    'zh-CN-YunyeNeural': '云野',
    'zh-CN-YunfengNeural': '云峰',
    'zh-CN-XiaoyuNeural': '晓渝',
    'zh-CN-XiaohanNeural': '晓涵',
    'zh-CN-XiaomoNeural': '晓墨',
    'zh-CN-XiaoqiuNeural': '晓秋',
    'zh-CN-XiaoruiNeural': '晓睿',
    'zh-CN-XiaoshuangNeural': '晓双',
    'zh-CN-XiaoxuanNeural': '晓萱',
    'zh-CN-XiaoyanNeural': '晓颜',
    'zh-CN-XiaozhenNeural': '晓甄',
    'zh-CN-YunhaoNeural': '云浩',
  };

  static String _displayNameOf(String shortName, String friendlyName) {
    final String? zh = _zhNames[shortName];
    if (zh != null) return zh;
    // FriendlyName 形如 "Microsoft Ava Online (Natural) - English (United States)"。
    final RegExpMatch? match =
        RegExp(r'Microsoft (.+?) Online').firstMatch(friendlyName);
    if (match != null) {
      return match
          .group(1)!
          .replaceAll('Multilingual', ' Multilingual')
          .trim();
    }
    return shortName;
  }
}

/// Sec-MS-GEC DRM v2 令牌生成，逐行移植 edge-tts master `src/edge_tts/drm.py`。
///
/// 微软把摘要做成了「魔改版 SHA-256 + CS64」：初始状态由输入前 7 字节推导、
/// 第 14 轮常量替换、长度字段偏移，均非标准 SHA-256，因此不能用 crypto 包。
/// Dart 侧全部运算限定在 32 位无符号域内（与 Python `& 0xFFFFFFFF` 一致），
/// 32x32 乘法在 Dart int64 中可能溢出为负，但仅取低 32 位，结果不变。
class _EdgeDrm {
  _EdgeDrm._();

  static const int _mask = 0xFFFFFFFF;
  static const int _winEpoch = 11644473600; // 1601→1970 秒差
  static const int _adjustment = 0xC9DC06A7;
  static const int _sigma0Adjustment = 0x059C0B80;
  static const int _sigma1Adjustment = 0x000B92C0;
  static const int _cs64Factor = 0x82893933;
  static const int _cs64Adjustment0 = 0xF2F90B1A;
  static const int _cs64Adjustment1 = 0x0B1A0000;

  static const List<int> _sha256Initial = <int>[
    0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
    0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
  ];
  static const List<int> _sha256State = <int>[
    0xFD9FBEA2, 0x91243CE7, 0xBE499094, 0xCD2E1E0A,
    0x6C006F49, 0x04BD35AB, 0xFEB0A7E4, 0x03EFFBD2,
  ];
  static const List<int> _roundConstants = <int>[
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5,
    0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
    0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
    0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
    0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC,
    0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7,
    0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
    0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
    0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
    0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3,
    0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5,
    0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
    0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
    0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
  ];
  static const List<int> _schedule = <int>[
    0xEB24BF9E, 0x1558691F, 0xA0C09EE2, 0x0CFA32BA,
    0xA622EE8C, 0xD1DD9491, 0xC0DD25A0, 0xF9E70AB6,
    0xF0C31573, 0x7058CE4E, 0x7188E606, 0x00E5AB33,
    0xD258B060, 0x72766564,
  ];
  // (coefficient, offset) 对，与 _CS64_COEFFICIENTS 一致。
  static const List<List<int>> _cs64Coefficients = <List<int>>[
    [0xE82E91B1, 0xB32700D0], [0x44DE24C6, 0x88DFF51D],
    [0x3BEB65BC, 0x29514038], [0xC89C5933, 0xB328CBDF],
    [0x8D1EC211, 0xD405B4D5], [0x314EF5D5, 0x26E55F3C],
    [0xE92491B1, 0x607801C6], [0xF0A5B9D5, 0x82B2C1FB],
    [0x06064CF3, 0xFA51A3DA], [0xDA79FA60, 0x207CC464],
    [0xBED20560, 0x3C3C74F3], [0x89F9C9F8, 0xD2D14B61],
    [0x35FA38C6, 0xBB04A2C1], [0xCB49E3C6, 0xC5626167],
  ];

  static int _rotr32(int x, int n) => ((x >> n) | (x << (32 - n))) & _mask;

  static int _rol16(int x) => ((x << 16) | (x >> 16)) & _mask;

  static int _sigma0(int x) => _rotr32(x, 7) ^ _rotr32(x, 18) ^ (x >> 3);

  static int _sigma1(int x) => _rotr32(x, 17) ^ _rotr32(x, 19) ^ (x >> 10);

  /// 生成 unixSeconds 对应的 v2 令牌（整 300 秒截断，与 edge-tts 一致）。
  static String token(int unixSeconds, String trustedClientToken) {
    int ticks = unixSeconds + _winEpoch;
    ticks -= ticks % 300; // 向下取整到 5 分钟边界
    final int filetime = ticks * 10000000; // 100ns 单位，int64 内安全
    final List<int> data = ascii.encode('$filetime$trustedClientToken');
    final Uint8List digest = _sha256Digest(data);
    final List<int> cs64 = _cs64Digest(data, digest);
    return '${_hexLe32(cs64[0])}${_hexLe32(cs64[1])}'
        '-${_hexBe(digest)}';
  }

  static int _be32(List<int> b, int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

  static int _le32(List<int> b, int o) =>
      b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

  static String _hexLe32(int x) {
    String h = x.toRadixString(16).padLeft(8, '0');
    // 小端字节序：两两一组倒序。
    final StringBuffer sb = StringBuffer();
    for (int i = 6; i >= 0; i -= 2) {
      sb.write(h.substring(i, i + 2));
    }
    return sb.toString().toUpperCase();
  }

  static String _hexBe(Uint8List bytes) {
    final StringBuffer sb = StringBuffer();
    for (final int b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString().toUpperCase();
  }

  /// 64 个调度字（含扩展），first 起为扩展位。
  static void _expandSchedule(List<int> w, int first) {
    for (int i = first; i < 64; i++) {
      w[i] = (_sigma1(w[i - 2]) + w[i - 7] + _sigma0(w[i - 15]) + w[i - 16]) &
          _mask;
    }
  }

  /// SHA-256 压缩函数；firstRound==14 时第 14 轮常量替换为 _adjustment
  /// （edge-tts _SHA256_BLOCK_CONSTANTS 的等价写法）。
  static List<int> _rounds(List<int> state, List<int> w, int firstRound) {
    int a = state[0], b = state[1], c = state[2], d = state[3];
    int e = state[4], f = state[5], g = state[6], h = state[7];
    for (int i = firstRound; i < 64; i++) {
      final int k =
          (i == 14 && firstRound == 14) ? _adjustment : _roundConstants[i];
      final int t1 = (h +
              (_rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25)) +
              (g ^ (e & (f ^ g))) +
              k +
              w[i]) &
          _mask;
      final int t2 = ((_rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22)) +
              ((a & b) | (c & (a | b)))) &
          _mask;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & _mask;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & _mask;
    }
    return <int>[a, b, c, d, e, f, g, h];
  }

  /// 由输入前 7 字节推导初始状态（对应 _sha256_init）。
  static List<int> _sha256Init(List<int> data) {
    final List<int> w = List<int>.filled(64, 0);
    w[14] = _be32(data, 0) >> 8; // int.from_bytes(data[:3], "big")
    w[15] = _be32(data, 3);
    for (int i = 16; i < 30; i++) {
      int value = _schedule[i - 16];
      if (i - 2 >= 14) {
        value += i == 16
            ? _sigma1(w[i - 2]) ^ _sigma1Adjustment
            : _sigma1(w[i - 2]);
      }
      if (i - 7 >= 14) value += w[i - 7];
      if (i - 15 >= 14) {
        value += i == 29
            ? _sigma0(w[i - 15]) ^ _sigma0Adjustment
            : _sigma0(w[i - 15]);
      }
      w[i] = value & _mask;
    }
    w[30] = (_sigma1(w[28]) +
            w[23] +
            _sigma0(w[15]) +
            w[14] +
            _adjustment -
            _roundConstants[14]) &
        _mask;
    _expandSchedule(w, 31);
    final List<int> working = _rounds(_sha256State, w, 14);
    return <int>[
      for (int i = 0; i < 8; i++)
        (_sha256Initial[i] + working[i]) & _mask
    ];
  }

  static Uint8List _sha256Digest(List<int> data) {
    if (data.length < 7) throw ArgumentError('token 输入过短');
    final int length = 57 + data.length;
    final List<int> padded = <int>[
      ...data.sublist(7),
      0x80,
      ...List<int>.filled((55 - length) % 64, 0),
    ];
    for (int i = 7; i >= 0; i--) {
      padded.add((length * 8 >> (i * 8)) & 0xFF);
    }
    List<int> state = _sha256Init(data);
    for (int offset = 0; offset < padded.length; offset += 64) {
      final List<int> w = List<int>.filled(64, 0);
      for (int i = 0; i < 16; i++) {
        w[i] = _be32(padded, offset + i * 4);
      }
      _expandSchedule(w, 16);
      final List<int> working = _rounds(state, w, 0);
      state = <int>[
        for (int i = 0; i < 8; i++)
          (state[i] + working[i]) & _mask
      ];
    }
    final Uint8List out = Uint8List(32);
    for (int i = 0; i < 8; i++) {
      out[i * 4] = (state[i] >> 24) & 0xFF;
      out[i * 4 + 1] = (state[i] >> 16) & 0xFF;
      out[i * 4 + 2] = (state[i] >> 8) & 0xFF;
      out[i * 4 + 3] = state[i] & 0xFF;
    }
    return out;
  }

  /// CS64 摘要，返回 (w1, w2) 两个 32 位字（小端拼接后即 cs64 hex）。
  static List<int> _cs64Digest(List<int> data, Uint8List digest) {
    final int keyA = _le32(digest, 0) | 1;
    final int keyB = _le32(digest, 4) | 1;
    final int factorA = (keyA * _cs64Factor) & _mask;
    final int factorB = (keyB * _cs64Factor) & _mask;
    final List<int> terms = <int>[];
    final List<int> offsets = <int>[];
    for (int i = 0; i < _cs64Coefficients.length; i++) {
      terms.add((_cs64Coefficients[i][0] * (i.isEven ? factorA : factorB)) &
          _mask);
      offsets.add(_cs64Coefficients[i][1]);
    }
    // _words_le4_even(b"\x00" + data)
    final List<int> input = <int>[0, ...data];
    final int paddedLen = ((input.length + 3) ~/ 4) * 4;
    final List<int> words = <int>[];
    for (int i = 0; i < paddedLen ~/ 4; i++) {
      int v = 0;
      for (int j = 0; j < 4; j++) {
        final int idx = i * 4 + j;
        v |= (idx < input.length ? input[idx] : 0) << (j * 8);
      }
      words.add(v);
    }
    if (words.length.isOdd) words.add(0);
    for (int i = 0; i < words.length; i++) {
      final int word = words[i];
      int term = word * (i.isEven ? keyA : keyB);
      int offset = _rol16(word) * (i.isEven ? 0xEF0569FB : 0xC31713DB);
      if (i == 0) {
        term += _cs64Adjustment0 * factorA;
        offset += _cs64Adjustment1;
      }
      terms.add(term & _mask);
      offsets.add(offset & _mask);
    }
    int swapAcc = 0, swapLast = 0, state = 0, acc = 0;
    for (int i = 0; i < terms.length; i += 2) {
      final int x = terms[i], y = terms[i + 1];
      int t = _rol16((offsets[i] + x) & _mask);
      int q = (t * 0x76F50F34) & _mask;
      swapAcc += ((_rol16(q) * 0xC3EFEA97) + q) & _mask;
      t = _rol16((offsets[i + 1] + y) & _mask);
      q = (t * 0x1881CE3C) & _mask;
      swapLast = ((_rol16(q) * 0x35BD1EC9) + q) & _mask;
      swapAcc = (swapAcc + swapLast) & _mask;

      state = (state * keyA + x) & _mask;
      state = (_rol16(state) * 0xCF98B111) & _mask;
      state = (_rol16(state) * 0x87085B9F) & _mask;
      state = (_rol16(state) * 0x12CEB96D) & _mask;
      state = (_rol16(state) * 0x257E1D83) & _mask;
      acc += state;
      t = (state * keyB + y) & _mask;
      t = (_rol16(t) * 0xA27416F5) & _mask;
      t = (_rol16(t) * 0xD38396FF) & _mask;
      state = (_rol16((_rol16(t) * 0x7C932B89) & _mask) * 0xBFA49F69) & _mask;
      acc = (acc + state) & _mask;
    }
    return <int>[swapLast ^ state, swapAcc ^ acc];
  }
}
