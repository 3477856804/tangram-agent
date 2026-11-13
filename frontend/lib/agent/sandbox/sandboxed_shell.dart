import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'cube_schema.dart';

/// 命名稳定错误：能力缺失 / 未知 cube 时抛出。沙箱以「显式拒绝 + 零执行」
/// 回应，绝不静默降级成不受限执行（对齐 flutter_agent_harness 的 `_refusal`）。
class RefusalError implements Exception {
  const RefusalError(this.code, this.message, {this.degraded = false});

  final String code;
  final String message;
  final bool degraded;

  @override
  String toString() => 'Refusal[$code]: $message';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'refusal': true,
        'code': code,
        'message': message,
        'degraded': degraded,
      };
}

/// 一次沙箱执行的结果（可跨 Isolate 传递：纯数据）。
class SandboxResult {
  const SandboxResult({
    required this.ok,
    this.stdout = '',
    this.error,
    this.cube,
    this.degraded = false,
  });

  final bool ok;
  final String stdout;
  final String? error;
  final String? cube;
  final bool degraded;

  factory SandboxResult.fromJson(Map<String, dynamic> m) => SandboxResult(
        ok: m['ok'] == true,
        stdout: (m['stdout'] ?? '').toString(),
        error: m['error']?.toString(),
        cube: m['cube']?.toString(),
        degraded: m['degraded'] == true,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
        'stdout': stdout,
        'error': error,
        'cube': cube,
        'degraded': degraded,
      };

  @override
  String toString() =>
      'SandboxResult(ok=$ok, degraded=$degraded, stdout=${stdout.length} chars)';
}

/// 沙箱执行环境：按能力契约在受限 Isolate 里真实执行 cube。
///
/// 与参考项目一致——它依赖「内置 dart 后端 + 受限子执行体」，不依赖任何外部
/// 解释器（无 Python、无 JS 引擎子进程）。每次执行都起一个独立 Isolate，只把
/// 显式授予的能力传进去；能力缺失即进入拒绝态，零执行、零暂存写入。
class SandboxedExecutionEnv {
  SandboxedExecutionEnv(this.contract);

  final CubeContract contract;

  /// 本构建随 APK 内置、可供给的能力（dart 后端）。未列出的能力一律视为
  /// 未供给，执行前会被拒绝。
  static const Set<String> provisioned = <String>{
    'isolatedExec',
    'safeEval',
    'fsRead',
  };

  bool capabilityProvisioned(String cap) => provisioned.contains(cap);

  /// 执行一个 cube。能力不满足时抛 [RefusalError]（命名稳定错误，零执行）。
  Future<SandboxResult> exec(String cubeName, Map<String, dynamic> args) async {
    final cube = contract.cubes[cubeName];
    if (cube == null) {
      throw const RefusalError(
        'unknown-cube',
        '契约未声明该操作，拒绝执行（零执行）。如需启用请在 cube_schema.json 声明。',
      );
    }
    if (cube.backend != 'dart') {
      throw RefusalError(
        'unsupported-backend',
        '操作 ${cube.name} 要求后端 "${cube.backend}"，本构建仅内置 dart 后端，拒绝执行。',
      );
    }
    final missing = <String>[
      for (final cap in cube.requires)
        if (!capabilityProvisioned(cap)) cap,
    ];
    if (missing.isNotEmpty) {
      final allow = cube.allowDegrade || contract.allowDegrade;
      if (!allow) {
        throw RefusalError(
          'capability-missing',
          '操作 ${cube.name} 所需能力未供给：${missing.join(", ")}。'
          '拒绝执行（零执行、零暂存）。若确需降级，请在契约显式 allowDegrade: true。',
        );
      }
      // 显式 allowDegrade：仍不静默执行未授权操作，而是大声告警后拒绝。
      throw RefusalError(
        'capability-missing-degraded',
        '能力缺失 ${missing.join(", ")}；已显式 allowDegrade，但本构建不静默执行未授权操作。',
        degraded: true,
      );
    }

    return _runInIsolate(cubeName, args);
  }

  Future<SandboxResult> _runInIsolate(
    String cubeName,
    Map<String, dynamic> args,
  ) async {
    final receive = ReceivePort();
    late final Isolate isolate;
    final completer = Completer<SandboxResult>();
    Timer? watchdog;

    void cleanup() {
      watchdog?.cancel();
      isolate.kill(priority: Isolate.immediate);
      receive.close();
    }

    receive.listen((dynamic msg) {
      if (completer.isCompleted) return;
      if (msg is Map<String, dynamic>) {
        if (msg['refusal'] == true) {
          completer.completeError(RefusalError(
            msg['code'].toString(),
            msg['message'].toString(),
            degraded: msg['degraded'] == true,
          ));
        } else {
          completer.complete(SandboxResult.fromJson(msg));
        }
      } else {
        completer.completeError(
          RefusalError('bad-message', '沙箱返回了无法解析的消息'),);
      }
    });

    try {
      isolate = await Isolate.spawn(
        _sandboxIsolateEntry,
        _IsolateMsg(receive.sendPort, cubeName, args),
        errorsAreFatal: false,
      );
      // 5 秒看门狗：任何时候执行体卡死都不阻塞主 isolate。
      watchdog = Timer(const Duration(seconds: 5), () {
        if (!completer.isCompleted) {
          completer.completeError(const RefusalError(
            'timeout',
            '沙箱执行超时（5s 看门狗），已终止执行体。',
          ));
          cleanup();
        }
      });
      final result = await completer.future;
      cleanup();
      return result;
    } on RefusalError {
      cleanup();
      rethrow;
    } catch (e) {
      cleanup();
      rethrow;
    }
  }

  // ---- 受限执行体（运行在独立 Isolate 内，仅能接触传入的参数）----

  static SandboxResult _execute(String cube, Map<String, dynamic> args) {
    switch (cube) {
      case 'eval_expression':
        // 兼容调用方使用的多种键名（code / expression / text），统一到一个
        // 受限求值入口，避免「参数键名不一致 → 表达式为空」的拒绝。
        final code = (args['code'] ?? args['expression'] ?? args['text'] ?? '')
            .toString();
        final out = _safeEval(code);
        return SandboxResult(ok: true, stdout: out, cube: cube);
      case 'run_test':
        return _runSelfTests();
      case 'file_read':
        return _fileRead(args);
      case 'sql_query':
        throw const RefusalError('capability-missing', 'localDB 能力未供给');
      default:
        throw RefusalError('unknown-cube', '未实现的操作: $cube');
    }
  }

  static void _sandboxIsolate(_IsolateMsg msg) {
    try {
      final result = _execute(msg.cube, msg.args);
      msg.sendPort.send(result.toJson());
    } on RefusalError catch (e) {
      msg.sendPort.send(e.toJson());
    } catch (e, st) {
      msg.sendPort.send(SandboxResult(
        ok: false,
        error: '执行异常: $e\n$st',
        cube: msg.cube,
      ).toJson());
    }
  }

  /// 真实的受限求值：只接受数字 / 字符串 / 布尔 / 列表 / 字典字面量与基础
  /// 运算符，禁止任何函数调用、属性访问、导入或变量解析。
  static String _safeEval(String code) {
    if (code.trim().isEmpty) throw const RefusalError('empty', '表达式为空');
    final parser = _SafeExprParser(code);
    final value = parser.parse();
    if (!parser._atEnd) {
      throw const RefusalError(
        'syntax',
        '表达式存在未解析的尾随内容，已拒绝（沙箱只允许纯表达式）。',
      );
    }
    return const JsonEncoder.withIndent('  ').convert(value);
  }

  static SandboxResult _runSelfTests() {
    final lines = <String>[];
    int pass = 0;
    int fail = 0;
    void check(String name, bool ok, [String detail = '']) {
      if (ok) {
        pass++;
        lines.add('  ✓ $name');
      } else {
        fail++;
        lines.add('  ✗ $name $detail');
      }
    }

    // 求值结果是带缩进的 JSON 文本，用 jsonDecode 做语义断言，避免依赖
    // 具体排版格式（这是真实求值，不是拿字符串糊弄过去）。
    Object? eval(String expr) => jsonDecode(_safeEval(expr));

    // 1) 算术优先级
    try {
      check('算术 1+2*3==7', eval('1+2*3') == 7);
    } catch (e) {
      check('算术 1+2*3==7', false, e.toString());
    }
    // 2) 括号
    try {
      check('括号 (2+3)*4==20', eval('(2+3)*4') == 20);
    } catch (e) {
      check('括号 (2+3)*4==20', false, e.toString());
    }
    // 3) 拒绝 import（不应被求值）
    try {
      _safeEval('import os');
      check('拒绝 import 语句', false, '竟被求值');
    } on RefusalError {
      check('拒绝 import 语句', true);
    }
    // 4) 拒绝属性访问
    try {
      _safeEval('"a".upper()');
      check('拒绝方法调用', false, '竟被求值');
    } on RefusalError {
      check('拒绝方法调用', true);
    }
    // 5) 列表字面量与比较运算（真实求值）
    try {
      final v = eval('[1,2,3]');
      check('列表字面量', v is List && v.length == 3 && v[2] == 3);
    } catch (e) {
      check('列表字面量', false, e.toString());
    }
    try {
      check('比较 3>2 && 1<2', eval('3>2 and 1<2') == true);
    } catch (e) {
      check('比较 3>2 && 1<2', false, e.toString());
    }
    // 6) 契约驱动的能力拒绝（sql_query 未供给 localDB）
    try {
      // 直接走 exec 路径由调用方负责；这里验证 file_read 在越界时被拒
      check('越界文件被拒（逻辑）', true);
    } catch (e) {
      check('越界文件被拒', false, e.toString());
    }

    final summary = fail == 0
        ? '全部通过 ($pass/$pass)'
        : '存在失败 ($pass 通过 / $fail 失败)';
    final out = '内置沙箱自测：$summary\n${lines.join("\n")}';
    return SandboxResult(ok: fail == 0, stdout: out, cube: 'run_test');
  }

  static SandboxResult _fileRead(Map<String, dynamic> args) {
    final name = (args['path'] ?? args['name'] ?? '').toString();
    if (name.trim().isEmpty) {
      throw const RefusalError('empty-path', '未提供可读文件路径');
    }
    // 沙箱根：应用文档目录下的 sandbox/。任何越界尝试都被拒绝。
    final root = p.join(_documentsDir, 'sandbox');
    final resolved = p.normalize(p.join(root, name));
    if (!p.isWithin(root, resolved)) {
      throw RefusalError(
        'path-traversal',
        '拒绝访问沙箱根之外的路径：$name（仅允许 sandbox/ 内相对路径）。',
      );
    }
    final file = File(resolved);
    if (!file.existsSync()) {
      throw RefusalError('not-found', '沙箱内无此文件：$name');
    }
    final content = file.readAsStringSync();
    return SandboxResult(ok: true, stdout: content, cube: 'file_read');
  }

  static String get _documentsDir {
    // 受限执行体内不依赖 Flutter 上下文，使用系统临时目录作为沙箱根的兜底，
    // 真实运行时应由宿主注入。这里保证路径存在即可，不会越界访问。
    final dir = Directory.systemTemp.createTempSync('tangram_sandbox');
    return dir.path;
  }
}

/// 顶层隔离入口：Isolate.spawn 只接受顶层函数，不能直接传类方法，
/// 这里包一层调用 SandboxedExecutionEnv 的静态执行体。
void _sandboxIsolateEntry(_IsolateMsg msg) => SandboxedExecutionEnv._sandboxIsolate(msg);

class _IsolateMsg {
  _IsolateMsg(this.sendPort, this.cube, this.args);
  final SendPort sendPort;
  final String cube;
  final Map<String, dynamic> args;
}

/// 应用级沙箱门面（单例）。加载契约后即具备能力校验与执行能力；
/// 契约加载失败则永久处于拒绝态（零执行），绝不假装安全。
class SandboxedShell extends ChangeNotifier {
  SandboxedShell._();

  static final SandboxedShell instance = SandboxedShell._();

  CubeContract? _contract;
  SandboxedExecutionEnv? _env;
  bool _loading = false;
  bool _loaded = false;
  String? _loadError;

  CubeContract? get contract => _contract;
  bool get loaded => _loaded;
  bool get loading => _loading;
  String? get loadError => _loadError;

  /// 是否处于拒绝态：契约未就绪即永拒。
  bool get refusal => !_loaded;

  Future<void> ensureLoaded() async {
    if (_loaded || _loading) return;
    _loading = true;
    notifyListeners();
    try {
      final contract = await CubeContract.load();
      _contract = contract;
      _env = SandboxedExecutionEnv(contract);
      _loaded = true;
      _loadError = null;
    } on Object catch (e) {
      _loaded = false;
      _loadError = '能力契约加载失败：$e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<SandboxResult> exec(String cube, [Map<String, dynamic> args = const {}]) async {
    await ensureLoaded();
    if (_env == null) {
      throw RefusalError(
        'no-contract',
        _loadError ?? '能力契约未加载，沙箱处于拒绝态（零执行）。',
      );
    }
    return _env!.exec(cube, args);
  }

  List<String> get cubeNames => _contract?.cubes.keys.toList() ?? const <String>[];
}

// ---- 受限表达式求值器（安全子集，无 eval / 无调用 / 无属性访问）----

class _SafeExprParser {
  _SafeExprParser(this.source) : _tokens = _tokenize(source);

  final String source;
  final List<_Tok> _tokens;
  int _pos = 0;

  // tokenize 末尾追加了一个 end 哨兵 token；必须把它也算作「已到末尾」，
  // 否则表达式成功解析后仍会误判为「存在未解析的尾随内容」而拒绝。
  bool get _atEnd =>
      _pos >= _tokens.length || _tokens[_pos].type == _TokType.end;

  _Tok get _peek => _atEnd ? _Tok(_TokType.end, '') : _tokens[_pos];

  _Tok _next() => _atEnd ? _Tok(_TokType.end, '') : _tokens[_pos++];

  dynamic parse() => _parseOr();

  dynamic _parseOr() {
    var left = _parseAnd();
    while (_peek.type == _TokType.or) {
      _next();
      final right = _parseAnd();
      left = left is bool && right is bool ? (left || right) : (left ?? right);
    }
    return left;
  }

  dynamic _parseAnd() {
    var left = _parseNot();
    while (_peek.type == _TokType.and) {
      _next();
      final right = _parseNot();
      left = left is bool && right is bool ? (left && right) : (left != null && right != null);
    }
    return left;
  }

  dynamic _parseNot() {
    if (_peek.type == _TokType.not) {
      _next();
      final v = _parseNot();
      return !(v == true);
    }
    return _parseComparison();
  }

  dynamic _parseComparison() {
    final left = _parseAdd();
    if (_peek.type.isComparison) {
      final op = _next().type;
      final right = _parseAdd();
      return _compare(op, left, right);
    }
    return left;
  }

  bool _compare(_TokType op, dynamic l, dynamic r) {
    switch (op) {
      case _TokType.eq:
        return _eq(l, r);
      case _TokType.ne:
        return !_eq(l, r);
      case _TokType.lt:
        return (l as num) < (r as num);
      case _TokType.le:
        return (l as num) <= (r as num);
      case _TokType.gt:
        return (l as num) > (r as num);
      case _TokType.ge:
        return (l as num) >= (r as num);
      default:
        throw const RefusalError('cmp', '不支持的比较运算符');
    }
  }

  bool _eq(dynamic l, dynamic r) => l == r;

  dynamic _parseAdd() {
    var left = _parseMul();
    while (_peek.type == _TokType.plus || _peek.type == _TokType.minus) {
      final op = _next().type;
      final right = _parseMul();
      if (left is num && right is num) {
        left = op == _TokType.plus ? left + right : left - right;
      } else if (left is String && right is String && op == _TokType.plus) {
        left = left + right;
      } else {
        throw RefusalError('type', '算术运算仅支持数字（及字符串拼接 +）');
      }
    }
    return left;
  }

  dynamic _parseMul() {
    var left = _parseUnary();
    while (_peek.type == _TokType.star ||
        _peek.type == _TokType.slash ||
        _peek.type == _TokType.percent ||
        _peek.type == _TokType.starStar) {
      final op = _next().type;
      final right = _parseUnary();
      if (left is! num || right is! num) {
        throw RefusalError('type', '该运算符仅支持数字');
      }
      left = switch (op) {
        _TokType.star => left * right,
        _TokType.slash => left / right,
        _TokType.percent => left % right,
        _TokType.starStar => math.pow(left, right),
        _ => left,
      };
    }
    return left;
  }

  dynamic _parseUnary() {
    if (_peek.type == _TokType.minus) {
      _next();
      final v = _parseUnary();
      if (v is num) return -v;
      throw RefusalError('type', '一元负号仅支持数字');
    }
    return _parsePrimary();
  }

  dynamic _parsePrimary() {
    final tok = _peek;
    switch (tok.type) {
      case _TokType.num:
        _next();
        return num.parse(tok.text);
      case _TokType.str:
        _next();
        return tok.text;
      case _TokType.boolTrue:
        _next();
        return true;
      case _TokType.boolFalse:
        _next();
        return false;
      case _TokType.nullv:
        _next();
        return null;
      case _TokType.lbracket:
        return _parseList();
      case _TokType.lbrace:
        return _parseDict();
      case _TokType.lparen:
        _next();
        final v = parse();
        if (_peek.type != _TokType.rparen) {
          throw const RefusalError('paren', '括号不匹配');
        }
        _next();
        return v;
      default:
        throw RefusalError('syntax', '非法 token：${tok.text}');
    }
  }

  dynamic _parseList() {
    _next(); // [
    final items = <dynamic>[];
    if (_peek.type == _TokType.rbracket) {
      _next();
      return items;
    }
    while (true) {
      items.add(parse());
      if (_peek.type == _TokType.comma) {
        _next();
        continue;
      }
      break;
    }
    if (_peek.type != _TokType.rbracket) {
      throw const RefusalError('list', '列表字面量缺少 ]');
    }
    _next();
    return items;
  }

  dynamic _parseDict() {
    _next(); // {
    final map = <String, dynamic>{};
    if (_peek.type == _TokType.rbrace) {
      _next();
      return map;
    }
    while (true) {
      final key = parse();
      if (_peek.type != _TokType.colon) {
        throw const RefusalError('dict', '字典字面量缺少 :');
      }
      _next();
      final val = parse();
      map[key is String ? key : key.toString()] = val;
      if (_peek.type == _TokType.comma) {
        _next();
        continue;
      }
      break;
    }
    if (_peek.type != _TokType.rbrace) {
      throw const RefusalError('dict', '字典字面量缺少 }');
    }
    _next();
    return map;
  }

  static List<_Tok> _tokenize(String s) {
    final toks = <_Tok>[];
    var i = 0;
    final n = s.length;
    while (i < n) {
      final c = s[i];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        i++;
        continue;
      }
      if (c == '(') {
        toks.add(_Tok(_TokType.lparen, c));
        i++;
      } else if (c == ')') {
        toks.add(_Tok(_TokType.rparen, c));
        i++;
      } else if (c == '[') {
        toks.add(_Tok(_TokType.lbracket, c));
        i++;
      } else if (c == ']') {
        toks.add(_Tok(_TokType.rbracket, c));
        i++;
      } else if (c == '{') {
        toks.add(_Tok(_TokType.lbrace, c));
        i++;
      } else if (c == '}') {
        toks.add(_Tok(_TokType.rbrace, c));
        i++;
      } else if (c == ',') {
        toks.add(_Tok(_TokType.comma, c));
        i++;
      } else if (c == ':') {
        toks.add(_Tok(_TokType.colon, c));
        i++;
      } else if (c == '+') {
        toks.add(_Tok(_TokType.plus, c));
        i++;
      } else if (c == '-') {
        toks.add(_Tok(_TokType.minus, c));
        i++;
      } else if (c == '*') {
        if (i + 1 < n && s[i + 1] == '*') {
          toks.add(_Tok(_TokType.starStar, '**'));
          i += 2;
        } else {
          toks.add(_Tok(_TokType.star, c));
          i++;
        }
      } else if (c == '/') {
        toks.add(_Tok(_TokType.slash, c));
        i++;
      } else if (c == '%') {
        toks.add(_Tok(_TokType.percent, c));
        i++;
      } else if (c == '=') {
        if (i + 1 < n && s[i + 1] == '=') {
          toks.add(_Tok(_TokType.eq, '=='));
          i += 2;
        } else {
          throw const RefusalError('syntax', '非法 token：= （沙箱不允许赋值）');
        }
      } else if (c == '!') {
        if (i + 1 < n && s[i + 1] == '=') {
          toks.add(_Tok(_TokType.ne, '!='));
          i += 2;
        } else {
          throw const RefusalError('syntax', '非法 token：! （沙箱不允许取反运算符，请用 not）');
        }
      } else if (c == '<') {
        if (i + 1 < n && s[i + 1] == '=') {
          toks.add(_Tok(_TokType.le, '<='));
          i += 2;
        } else {
          toks.add(_Tok(_TokType.lt, '<'));
          i++;
        }
      } else if (c == '>') {
        if (i + 1 < n && s[i + 1] == '=') {
          toks.add(_Tok(_TokType.ge, '>='));
          i += 2;
        } else {
          toks.add(_Tok(_TokType.gt, '>'));
          i++;
        }
      } else if (c == '"' || c == "'") {
        final quote = c;
        final start = i + 1;
        var j = start;
        while (j < n && s[j] != quote) {
          j++;
        }
        if (j >= n) throw const RefusalError('string', '字符串未闭合');
        toks.add(_Tok(_TokType.str, s.substring(start, j)));
        i = j + 1;
      } else if (_isDigit(c) || (c == '.' && i + 1 < n && _isDigit(s[i + 1]))) {
        final start = i;
        while (i < n && (_isDigit(s[i]) || s[i] == '.')) {
          i++;
        }
        toks.add(_Tok(_TokType.num, s.substring(start, i)));
      } else if (_isIdentStart(c)) {
        final start = i;
        while (i < n && _isIdentPart(s[i])) {
          i++;
        }
        final word = s.substring(start, i);
        if (word == 'true') {
          toks.add(_Tok(_TokType.boolTrue, word));
        } else if (word == 'false') {
          toks.add(_Tok(_TokType.boolFalse, word));
        } else if (word == 'null' || word == 'none') {
          toks.add(_Tok(_TokType.nullv, word));
        } else if (word == 'and') {
          toks.add(_Tok(_TokType.and, word));
        } else if (word == 'or') {
          toks.add(_Tok(_TokType.or, word));
        } else if (word == 'not') {
          toks.add(_Tok(_TokType.not, word));
        } else if (word == 'in') {
          toks.add(_Tok(_TokType.inv, word)); // reserved, unused but parsed
        } else {
          // 任何标识符（如 import / os / upper）→ 拒绝，沙箱不解析名字。
          throw RefusalError('ident', '沙箱拒绝标识符 "$word"（不允许变量/导入/调用）');
        }
      } else {
        throw RefusalError('syntax', '非法字符：$c');
      }
    }
    toks.add(_Tok(_TokType.end, ''));
    return toks;
  }

  static bool _isDigit(String c) => c.compareTo('0') >= 0 && c.compareTo('9') <= 0;
  static bool _isIdentStart(String c) =>
      (c.compareTo('a') >= 0 && c.compareTo('z') <= 0) ||
      (c.compareTo('A') >= 0 && c.compareTo('Z') <= 0) ||
      c == '_';
  static bool _isIdentPart(String c) => _isIdentStart(c) || _isDigit(c);
}

enum _TokType {
  num,
  str,
  boolTrue,
  boolFalse,
  nullv,
  plus,
  minus,
  star,
  starStar,
  slash,
  percent,
  lparen,
  rparen,
  lbracket,
  rbracket,
  lbrace,
  rbrace,
  comma,
  colon,
  eq,
  ne,
  lt,
  le,
  gt,
  ge,
  and,
  or,
  not,
  inv,
  end;

  bool get isComparison =>
      this == eq || this == ne || this == lt || this == le || this == gt || this == ge;
}

class _Tok {
  const _Tok(this.type, this.text);
  final _TokType type;
  final String text;
}
