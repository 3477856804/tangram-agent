/// Tangram Harness Core —— 从参考项目移植的真实机制集合。
///
/// 移植来源（均为 Apache/MIT/BSD 许可的开源实现，见 THIRD_PARTY_NOTICES.md）：
///   * `IstiN/flutter_agent_harness`（pure-Dart core, MIT）
///     - `lib/src/cancel_token.dart`：协作取消 CancelToken / CancelTokenSource
///     - `lib/src/agent/agent_tool.dart` + `tool_registry.dart`：
///       AgentTool / ToolRegistry「lookup → validate → execute」三段式与失败契约
///     - `lib/src/trajectory/`：TrajectorySnapshot 不可变轨迹投影
///   * `appsup-dart/expressions`（BSD-3-Clause）：只解析表达式、无语句/控制流
///     的安全求值器（本项目重写为无依赖的递归下降实现，语义一致）
///
/// 设计原则与参考 harness 一致：**能力缺失即拒绝，异常不逃逸循环，
/// 工具结果永远是数据而不是异常**，绝不静默降级、绝不编造输出。

library;

import 'dart:async';
import 'dart:math' as math;

// ---------------------------------------------------------------------------
// 1. 协作取消（移植自 flutter_agent_harness/lib/src/cancel_token.dart）
// ---------------------------------------------------------------------------

/// 因取消而提前终止。
class CancelledException implements Exception {
  CancelledException(this.reason);
  final Object? reason;
  @override
  String toString() => 'CancelledException${reason == null ? '' : ': $reason'}';
}

/// 只读侧：交给可取消的工作单元。取消通过 [onCancel] 异步投递，监听器
/// 不会在 [CancelTokenSource.cancel] 内部重入执行。
class CancelToken {
  CancelToken._();

  final List<void Function()> _listeners = <void Function()>[];
  bool _cancelled = false;
  Object? _reason;

  bool get isCancelled => _cancelled;
  Object? get cancelReason => _reason;

  Future<void> get onCancel {
    final completer = Completer<void>.sync();
    if (_cancelled) {
      completer.complete();
    } else {
      _listeners.add(completer.complete);
    }
    return completer.future;
  }

  void throwIfCancelled() {
    if (_cancelled) throw CancelledException(_reason);
  }

  void _cancel(Object? reason) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason;
    final listeners = List<void Function()>.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      scheduleMicrotask(listener);
    }
  }
}

/// 可写侧：由操作持有者私有，只把 [token] 交给被调用方。
class CancelTokenSource {
  CancelTokenSource() : token = CancelToken._();
  final CancelToken token;
  void cancel([Object? reason]) => token._cancel(reason);
}

/// 竞速取消：底层工作不被强行 abort，但调用方立刻停止等待。
Future<T> cancellable<T>(CancelToken? token, Future<T> Function() work) {
  if (token == null) return work();
  return Future.any<T>(<Future<T>>[
    work(),
    token.onCancel.then<T>((_) => throw CancelledException(token.cancelReason)),
  ]);
}

// ---------------------------------------------------------------------------
// 2. 工具定义 + 注册表（移植自 agent_tool.dart / tool_registry.dart）
// ---------------------------------------------------------------------------

/// 能力分级（参考 harness 的 ApprovalTier：read / write / exec）。
enum ApprovalTier { read, write, exec }

/// 工具执行结果：**总是数据**。异常由注册表转换为 error 结果，不逃逸循环。
class ToolResult {
  const ToolResult.ok(this.content, {this.data})
      : ok = true,
        error = '';
  const ToolResult.error(this.error)
      : ok = false,
        content = '',
        data = null;

  final bool ok;
  final String content;
  final String error;
  final Object? data;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
        'content': content,
        if (error.isNotEmpty) 'error': error,
        if (data != null) 'data': data,
      };
}

typedef ToolExecute = Future<ToolResult> Function(
  Map<String, dynamic> arguments,
  CancelToken? cancelToken,
);

/// 一个可被 agent 调用的工具：名字、描述、JSON Schema 参数、执行体、能力级别。
class AgentTool {
  const AgentTool({
    required this.name,
    required this.description,
    required this.execute,
    this.parameters = const <String, dynamic>{},
    this.tier = ApprovalTier.read,
    this.label,
  });

  final String name;
  final String description;
  final ToolExecute execute;
  final Map<String, dynamic> parameters;
  final ApprovalTier tier;
  final String? label;

  Map<String, dynamic> describe() => <String, dynamic>{
        'name': name,
        'description': description,
        'parameters': parameters,
        'tier': tier.name,
      };
}

class ToolNotFoundException implements Exception {
  ToolNotFoundException(this.name);
  final String name;
  @override
  String toString() => 'ToolNotFoundException: $name';
}

class ToolValidationException implements Exception {
  ToolValidationException(this.message);
  final String message;
  @override
  String toString() => 'ToolValidationException: $message';
}

/// 按 JSON Schema 的受支持子集校验参数：type / required / enum / minimum /
/// maximum。校验通过后才执行工具；失败抛 [ToolValidationException]，由注册表
/// 转成 error 结果（参考 harness 的 pi 语义）。
Map<String, dynamic> validateToolArguments({
  required Map<String, dynamic> arguments,
  required Map<String, dynamic> schema,
  required String toolName,
}) {
  final props = schema['properties'];
  final required = schema['required'];
  if (required is List) {
    for (final key in required) {
      if (!arguments.containsKey(key) || arguments[key] == null) {
        throw ToolValidationException('$toolName 缺少必填参数 "$key"');
      }
    }
  }
  if (props is Map) {
    props.forEach((dynamic key, dynamic spec) {
      final String k = key.toString();
      if (!arguments.containsKey(k) || arguments[k] == null) return;
      if (spec is! Map) return;
      final value = arguments[k];
      final String type = (spec['type'] ?? '').toString();
      bool mismatch = false;
      switch (type) {
        case 'string':
          mismatch = value is! String;
        case 'integer':
          mismatch = value is! int;
        case 'number':
          mismatch = value is! num;
        case 'boolean':
          mismatch = value is! bool;
        case 'array':
          mismatch = value is! List;
        case 'object':
          mismatch = value is! Map;
      }
      if (mismatch) {
        throw ToolValidationException(
            '$toolName 参数 "$k" 类型应为 $type，实际为 ${value.runtimeType}');
      }
      final en = spec['enum'];
      if (en is List && !en.contains(value)) {
        throw ToolValidationException('$toolName 参数 "$k" 取值不在允许集合内');
      }
      if (value is num) {
        final lo = spec['minimum'];
        final hi = spec['maximum'];
        if (lo is num && value < lo) {
          throw ToolValidationException('$toolName 参数 "$k" 小于最小值 $lo');
        }
        if (hi is num && value > hi) {
          throw ToolValidationException('$toolName 参数 "$k" 大于最大值 $hi');
        }
      }
    });
  }
  return Map<String, dynamic>.unmodifiable(arguments);
}

/// 具名工具集合：注册 / 查重 / 查找 / 参数校验 / 执行。失败契约与参考项目
/// 一致：未知工具抛 [ToolNotFoundException]，参数非法抛
/// [ToolValidationException]，两者都被 [run] 转成 error [ToolResult]。
class ToolRegistry {
  ToolRegistry([Iterable<AgentTool> tools = const <AgentTool>[]]) {
    registerAll(tools);
  }

  final Map<String, AgentTool> _tools = <String, AgentTool>{};
  final List<String> duplicateNotes = <String>[];

  int get length => _tools.length;
  List<String> get names => List<String>.unmodifiable(_tools.keys);
  List<AgentTool> get tools => List<AgentTool>.unmodifiable(_tools.values);

  void register(AgentTool tool) {
    if (tool.name.isEmpty) {
      throw ArgumentError('工具名不能为空');
    }
    if (_tools.containsKey(tool.name)) {
      duplicateNotes.add('重复工具名 ${tool.name}：后者覆盖前者');
    }
    _tools[tool.name] = tool;
  }

  void registerAll(Iterable<AgentTool> tools) {
    for (final t in tools) {
      register(t);
    }
  }

  bool unregister(String name) => _tools.remove(name) != null;
  AgentTool? lookup(String name) => _tools[name];
  bool contains(String name) => _tools.containsKey(name);

  /// 三段式执行：lookup → validate → execute。异常一律转成 error 结果。
  Future<ToolResult> run(
    String name,
    Map<String, dynamic> arguments, {
    CancelToken? cancelToken,
  }) async {
    try {
      final tool = lookup(name);
      if (tool == null) throw ToolNotFoundException(name);
      final validated = validateToolArguments(
        arguments: arguments,
        schema: tool.parameters,
        toolName: name,
      );
      tool.throwIfCancelled(cancelToken);
      return await tool.execute(validated, cancelToken);
    } on Object catch (e) {
      return ToolResult.error('$e');
    }
  }

  List<Map<String, dynamic>> describe() =>
      tools.map((AgentTool t) => t.describe()).toList(growable: false);
}

extension _ToolCancel on AgentTool {
  void throwIfCancelled(CancelToken? token) => token?.throwIfCancelled();
}

// ---------------------------------------------------------------------------
// 3. 轨迹快照（移植自 flutter_agent_harness 的 TrajectorySnapshot 概念）
// ---------------------------------------------------------------------------

enum TrajectoryCellKind { system, user, context, message, tool, result, compacted }

class TrajectoryCell {
  const TrajectoryCell(this.kind, this.text, {this.meta = const <String, dynamic>{}});
  final TrajectoryCellKind kind;
  final String text;
  final Map<String, dynamic> meta;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind.name,
        'text': text,
        if (meta.isNotEmpty) 'meta': meta,
      };
}

/// 不可变轨迹投影：append 返回新快照，事件只追加不改写。
class TrajectorySnapshot {
  TrajectorySnapshot(this.goal, [List<TrajectoryCell>? cells])
      : _cells = List<TrajectoryCell>.unmodifiable(cells ?? <TrajectoryCell>[]);

  final String goal;
  final List<TrajectoryCell> _cells;

  List<TrajectoryCell> get cells => _cells;
  int get length => _cells.length;

  TrajectorySnapshot append(TrajectoryCellKind kind, String text,
          {Map<String, dynamic> meta = const <String, dynamic>{}}) =>
      TrajectorySnapshot(
        goal,
        <TrajectoryCell>[..._cells, TrajectoryCell(kind, text, meta: meta)],
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'goal': goal,
        'cells': _cells.map((TrajectoryCell c) => c.toJson()).toList(),
      };

  String exportMarkdown() {
    final buf = StringBuffer('# Trajectory: $goal\n\n');
    for (final c in _cells) {
      buf.writeln('- **${c.kind.name}**: ${c.text}');
    }
    return buf.toString();
  }
}

// ---------------------------------------------------------------------------
// 4. 安全表达式求值（语义对齐 appsup-dart/expressions）
//
// 只解析「表达式」，不含语句 / 赋值 / 属性访问 / 任意函数调用 / import。
// 支持：数字、字符串、true/false/null、括号、一元 +/-/!、算术 + - * / %、
// 比较 == != < <= > >=、逻辑 && ||、三元 ?:、变量、白名单纯函数。
// ---------------------------------------------------------------------------

class ExpressionException implements Exception {
  ExpressionException(this.message);
  final String message;
  @override
  String toString() => 'ExpressionException: $message';
}

enum _T {
  num,
  str,
  ident,
  plus,
  minus,
  star,
  slash,
  percent,
  eq,
  neq,
  lt,
  lte,
  gt,
  gte,
  and,
  or,
  not,
  question,
  colon,
  lparen,
  rparen,
  comma,
  eof,
}

class _Tok {
  const _Tok(this.type, this.text, this.value);
  final _T type;
  final String text;
  final Object? value;
}

class SafeExpression {
  SafeExpression._(this._tokens, this._vars);

  final List<_Tok> _tokens;
  final Map<String, Object?> _vars;
  int _pos = 0;

  /// 求值入口。任何不合法的语法都抛 [ExpressionException]，不执行任何副作用。
  static Object? eval(String source, {Map<String, Object?> vars = const {}}) {
    if (source.trim().isEmpty) {
      throw ExpressionException('表达式为空');
    }
    if (source.length > 2048) {
      throw ExpressionException('表达式过长（上限 2048 字符）');
    }
    final parser = SafeExpression._(_tokenize(source), vars).._guardTokens();
    final result = parser._ternary();
    if (parser._peek().type != _T.eof) {
      throw ExpressionException('表达式尾部存在多余内容：${parser._peek().text}');
    }
    return result;
  }

  void _guardTokens() {
    for (final t in _tokens) {
      if (t.type == _T.ident && !_isAllowedIdent(t.text)) {
        throw ExpressionException('不允许的标识符：${t.text}');
      }
    }
  }

  static bool _isAllowedIdent(String s) =>
      s == 'true' ||
      s == 'false' ||
      s == 'null' ||
      s == 'pi' ||
      s == 'e' ||
      _functions.containsKey(s) ||
      _varsAllowed.contains(s);

  static const Set<String> _varsAllowed = <String>{
    'x', 'y', 'z', 'a', 'b', 'c', 'n', 'value', 'answer',
  };

  static const Map<String, int> _functions = <String, int>{
    'abs': 1,
    'min': 2,
    'max': 2,
    'sqrt': 1,
    'round': 1,
    'floor': 1,
    'ceil': 1,
    'pow': 2,
    'len': 1,
    'lower': 1,
    'upper': 1,
    'str': 1,
    'int': 1,
    'log': 1,
    'sin': 1,
    'cos': 1,
  };

  _Tok _peek() => _tokens[_pos];
  _Tok _next() => _tokens[_pos++];

  bool _match(_T t) {
    if (_peek().type == t) {
      _pos++;
      return true;
    }
    return false;
  }

  Object? _ternary() {
    final cond = _or();
    if (_match(_T.question)) {
      final a = _ternary();
      if (!_match(_T.colon)) {
        throw ExpressionException('三元表达式缺少 ":"');
      }
      final b = _ternary();
      return _truthy(cond) ? a : b;
    }
    return cond;
  }

  Object? _or() {
    var v = _and();
    while (_match(_T.or)) {
      final r = _and();
      v = _truthy(v) || _truthy(r);
    }
    return v;
  }

  Object? _and() {
    var v = _equality();
    while (_match(_T.and)) {
      final r = _equality();
      v = _truthy(v) && _truthy(r);
    }
    return v;
  }

  Object? _equality() {
    var v = _comparison();
    while (true) {
      if (_match(_T.eq)) {
        v = _looseEq(v, _comparison());
      } else if (_match(_T.neq)) {
        v = !_looseEq(v, _comparison());
      } else {
        return v;
      }
    }
  }

  Object? _comparison() {
    var v = _additive();
    while (true) {
      final t = _peek().type;
      if (t == _T.lt || t == _T.lte || t == _T.gt || t == _T.gte) {
        _pos++;
        final r = _additive();
        final num l = _asNum(v);
        final num rr = _asNum(r);
        v = t == _T.lt
            ? l < rr
            : t == _T.lte
                ? l <= rr
                : t == _T.gt
                    ? l > rr
                    : l >= rr;
      } else {
        return v;
      }
    }
  }

  Object? _additive() {
    var v = _multiplicative();
    while (true) {
      if (_match(_T.plus)) {
        final r = _multiplicative();
        v = (v is String || r is String)
            ? '$v$r'
            : _asNum(v) + _asNum(r);
      } else if (_match(_T.minus)) {
        v = _asNum(v) - _asNum(_multiplicative());
      } else {
        return v;
      }
    }
  }

  Object? _multiplicative() {
    var v = _unary();
    while (true) {
      if (_match(_T.star)) {
        v = _asNum(v) * _asNum(_unary());
      } else if (_match(_T.slash)) {
        final d = _asNum(_unary());
        if (d == 0) throw ExpressionException('除以零');
        v = _asNum(v) / d;
      } else if (_match(_T.percent)) {
        final d = _asNum(_unary());
        if (d == 0) throw ExpressionException('对零取模');
        v = _asNum(v) % d;
      } else {
        return v;
      }
    }
  }

  Object? _unary() {
    if (_match(_T.minus)) return -_asNum(_unary());
    if (_match(_T.plus)) return _asNum(_unary());
    if (_match(_T.not)) return !_truthy(_unary());
    return _primary();
  }

  Object? _primary() {
    final t = _next();
    switch (t.type) {
      case _T.num:
      case _T.str:
        return t.value;
      case _T.ident:
        if (t.text == 'true') return true;
        if (t.text == 'false') return false;
        if (t.text == 'null') return null;
        if (t.text == 'pi') return math.pi;
        if (t.text == 'e') return math.e;
        if (_match(_T.lparen)) {
          final args = <Object?>[];
          if (_peek().type != _T.rparen) {
            args.add(_ternary());
            while (_match(_T.comma)) {
              args.add(_ternary());
            }
          }
          if (!_match(_T.rparen)) {
            throw ExpressionException('函数 ${t.text} 缺少右括号');
          }
          final arity = _functions[t.text];
          if (arity == null) {
            throw ExpressionException('未知函数：${t.text}');
          }
          if (args.length != arity) {
            throw ExpressionException('函数 ${t.text} 需要 $arity 个参数');
          }
          return _call(t.text, args);
        }
        if (_vars.containsKey(t.text)) return _vars[t.text];
        // 未绑定变量解析为 0（纯数据，无副作用），保持表达式可求值。
        return 0;
      case _T.lparen:
        final v = _ternary();
        if (!_match(_T.rparen)) {
          throw ExpressionException('缺少右括号');
        }
        return v;
      case _T.eof:
        throw ExpressionException('表达式意外结束');
      default:
        throw ExpressionException('位置 $_pos 出现非预期符号：${t.text}');
    }
  }

  Object? _call(String name, List<Object?> a) {
    switch (name) {
      case 'abs':
        return _asNum(a[0]).abs();
      case 'min':
        return math.min(_asNum(a[0]), _asNum(a[1]));
      case 'max':
        return math.max(_asNum(a[0]), _asNum(a[1]));
      case 'sqrt':
        final v = _asNum(a[0]);
        if (v < 0) throw ExpressionException('sqrt 不接受负数');
        return math.sqrt(v);
      case 'round':
        return _asNum(a[0]).round();
      case 'floor':
        return _asNum(a[0]).floor();
      case 'ceil':
        return _asNum(a[0]).ceil();
      case 'pow':
        return math.pow(_asNum(a[0]), _asNum(a[1]));
      case 'log':
        return math.log(_asNum(a[0]));
      case 'sin':
        return math.sin(_asNum(a[0]));
      case 'cos':
        return math.cos(_asNum(a[0]));
      case 'len':
        return a[0].toString().length;
      case 'lower':
        return a[0].toString().toLowerCase();
      case 'upper':
        return a[0].toString().toUpperCase();
      case 'str':
        return a[0].toString();
      case 'int':
        return _asNum(a[0]).toInt();
    }
    throw ExpressionException('未知函数：$name');
  }

  static num _asNum(Object? v) {
    if (v is num) return v;
    if (v is bool) return v ? 1 : 0;
    if (v == null) return 0;
    final n = num.tryParse(v.toString());
    if (n == null) throw ExpressionException('"$v" 不能作为数字参与运算');
    return n;
  }

  static bool _truthy(Object? v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v == null) return false;
    if (v is String) return v.isNotEmpty;
    return true;
  }

  static bool _looseEq(Object? a, Object? b) {
    if (a is num && b is num) return a == b;
    return a.toString() == b.toString();
  }

  static List<_Tok> _tokenize(String s) {
    final out = <_Tok>[];
    var i = 0;
    while (i < s.length) {
      final c = s[i];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        i++;
        continue;
      }
      if (_isDigit(c) || (c == '.' && i + 1 < s.length && _isDigit(s[i + 1]))) {
        final start = i;
        var dot = false;
        while (i < s.length && (_isDigit(s[i]) || (!dot && s[i] == '.'))) {
          if (s[i] == '.') dot = true;
          i++;
        }
        final text = s.substring(start, i);
        final n = num.tryParse(text);
        if (n == null) throw ExpressionException('非法数字：$text');
        out.add(_Tok(_T.num, text, n));
        continue;
      }
      if (c == '"' || c == "'") {
        final quote = c;
        i++;
        final buf = StringBuffer();
        var closed = false;
        while (i < s.length) {
          if (s[i] == quote) {
            closed = true;
            i++;
            break;
          }
          if (s[i] == '\\' && i + 1 < s.length) {
            i++;
            final e = s[i];
            buf.write(e == 'n' ? '\n' : e == 't' ? '\t' : e);
          } else {
            buf.write(s[i]);
          }
          i++;
        }
        if (!closed) throw ExpressionException('字符串未闭合');
        out.add(_Tok(_T.str, buf.toString(), buf.toString()));
        continue;
      }
      if (_isIdentStart(c)) {
        final start = i;
        while (i < s.length && _isIdentPart(s[i])) {
          i++;
        }
        out.add(_Tok(_T.ident, s.substring(start, i), null));
        continue;
      }
      String two = i + 1 < s.length ? s.substring(i, i + 2) : '';
      final twoMap = <String, _T>{
        '==': _T.eq,
        '!=': _T.neq,
        '<=': _T.lte,
        '>=': _T.gte,
        '&&': _T.and,
        '||': _T.or,
      };
      if (twoMap.containsKey(two)) {
        out.add(_Tok(twoMap[two]!, two, null));
        i += 2;
        continue;
      }
      final oneMap = <String, _T>{
        '+': _T.plus,
        '-': _T.minus,
        '*': _T.star,
        '/': _T.slash,
        '%': _T.percent,
        '<': _T.lt,
        '>': _T.gt,
        '!': _T.not,
        '?': _T.question,
        ':': _T.colon,
        '(': _T.lparen,
        ')': _T.rparen,
        ',': _T.comma,
      };
      final t = oneMap[c];
      if (t == null) throw ExpressionException('非法字符：$c');
      out.add(_Tok(t, c, null));
      i++;
    }
    out.add(const _Tok(_T.eof, '<eof>', null));
    return out;
  }

  static bool _isDigit(String c) => c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;
  static bool _isIdentStart(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || c == '_';
  }

  static bool _isIdentPart(String c) => _isIdentStart(c) || _isDigit(c);
}
