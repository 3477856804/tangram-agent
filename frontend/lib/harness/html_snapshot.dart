/// 轻量 HTML 快照解析（纯 Dart，无第三方依赖）。
///
/// Team Computer 的浏览器走真实 HTTP 请求，本文件负责把返回的 HTML 解析成
/// 「可被模型/用户操作」的结构：
///   * 页面标题与可见正文；
///   * 链接（L1、L2…）及解析后的绝对地址；
///   * 表单（F1…）与字段（I1…），含默认值 / hidden / 密码类型；
///   * `render()` 生成稳定的文字快照，供 Agent 工具与页面直接展示。
///
/// 真实性边界：解析器只处理服务端返回的 HTML，不执行 JavaScript，
/// 因此脚本渲染出来的内容不会被伪造出来；调用方必须如实告知这一限制。

library;

/// 页面上的一个链接。
class HtmlLink {
  const HtmlLink({required this.ref, required this.text, required this.href});

  final String ref;
  final String text;
  final String href;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ref': ref,
    'text': text,
    'href': href,
  };
}

/// 表单里的一个字段。
class HtmlField {
  const HtmlField({
    required this.ref,
    required this.formRef,
    required this.name,
    required this.type,
    required this.label,
    required this.value,
    required this.hidden,
  });

  final String ref;
  final String formRef;
  final String name;
  final String type;
  final String label;
  final String value;
  final bool hidden;

  bool get isPassword => type.toLowerCase() == 'password';
  bool get isSubmit =>
      type.toLowerCase() == 'submit' || type.toLowerCase() == 'button';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ref': ref,
    'form_ref': formRef,
    'name': name,
    'type': type,
    'label': label,
    'value': isPassword ? '' : value,
    'hidden': hidden,
  };
}

/// 一个表单。
class HtmlForm {
  const HtmlForm({
    required this.ref,
    required this.action,
    required this.method,
    required this.fields,
  });

  final String ref;
  final String action;
  final String method;
  final List<HtmlField> fields;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ref': ref,
    'action': action,
    'method': method,
    'fields': fields
        .where((HtmlField f) => !f.hidden)
        .map((HtmlField f) => f.toJson())
        .toList(),
  };
}

/// 一次页面快照。
class HtmlSnapshot {
  const HtmlSnapshot({
    required this.url,
    required this.title,
    required this.text,
    required this.links,
    required this.forms,
  });

  final String url;
  final String title;
  final String text;
  final List<HtmlLink> links;
  final List<HtmlForm> forms;

  HtmlLink? link(String ref) {
    for (final HtmlLink l in links) {
      if (l.ref == ref) return l;
    }
    return null;
  }

  HtmlForm? form(String ref) {
    for (final HtmlForm f in forms) {
      if (f.ref == ref) return f;
    }
    return null;
  }

  HtmlField? field(String ref) {
    for (final HtmlForm f in forms) {
      for (final HtmlField x in f.fields) {
        if (x.ref == ref) return x;
      }
    }
    return null;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'url': url,
    'title': title,
    'text': text,
    'links': links.map((HtmlLink l) => l.toJson()).toList(),
    'forms': forms.map((HtmlForm f) => f.toJson()).toList(),
  };

  /// 稳定的文字快照：模型可读，页面也可直接渲染。
  String render({Map<String, String> filled = const <String, String>{}}) {
    final StringBuffer buf = StringBuffer();
    buf.writeln('URL: $url');
    buf.writeln('标题: ${title.isEmpty ? '(无标题)' : title}');
    if (text.isNotEmpty) {
      buf.writeln();
      buf.writeln(text);
    }
    if (links.isNotEmpty) {
      buf.writeln();
      buf.writeln('链接（点击用 browser_act click <ref>）：');
      for (final HtmlLink l in links) {
        buf.writeln('- [${l.ref}] ${l.text} -> ${l.href}');
      }
    }
    if (forms.isNotEmpty) {
      buf.writeln();
      buf.writeln(
        '表单（填写用 browser_act fill <ref> <值>，提交用 submit <form_ref>）：',
      );
      for (final HtmlForm f in forms) {
        final String action = f.action.isEmpty ? url : f.action;
        buf.writeln('- [${f.ref}] ${f.method} $action');
        for (final HtmlField x in f.fields) {
          if (x.hidden) continue;
          final String shown = filled[x.ref] ??
              (x.isPassword ? '******' : x.value);
          buf.writeln(
            '  - [${x.ref}] ${x.name.isEmpty ? '(无名)' : x.name}'
            ' (${x.type})${x.label.isEmpty ? '' : ' · ${x.label}'}'
            '${shown.isEmpty ? '' : ' = "$shown"'}',
          );
        }
      }
    }
    return buf.toString().trimRight();
  }
}

/// 解析 HTML，生成 [HtmlSnapshot]。
///
/// [maxText] / [maxLinks] / [maxFields] 为上限，避免恶意大页面撑爆上下文。
HtmlSnapshot parseHtmlSnapshot({
  required String url,
  required String html,
  int maxText = 4000,
  int maxLinks = 80,
  int maxFields = 60,
}) {
  final Uri base = Uri.tryParse(url) ?? Uri();
  final String cleaned = _stripNonVisible(html);
  final String title = _decodeEntities(
    _firstGroup(RegExp(r'<title\b[^>]*>([\s\S]*?)</title>', caseSensitive: false), cleaned) ?? '',
  ).trim();

  final List<HtmlLink> links = <HtmlLink>[];
  final RegExp linkRe =
      RegExp(r'<a\b([^>]*)>([\s\S]*?)</a>', caseSensitive: false);
  for (final RegExpMatch m in linkRe.allMatches(cleaned)) {
    if (links.length >= maxLinks) break;
    final String attrs = m.group(1) ?? '';
    final String rawHref = (_attr(attrs, 'href') ?? '').trim();
    if (rawHref.isEmpty || rawHref.startsWith('#')) continue;
    final String lower = rawHref.toLowerCase();
    if (lower.startsWith('javascript:') || lower.startsWith('data:')) continue;
    final String? resolved = _resolve(base, rawHref);
    if (resolved == null) continue;
    String label = _visibleText(m.group(2) ?? '');
    if (label.isEmpty) label = (_attr(attrs, 'title') ?? '').trim();
    if (label.isEmpty) label = rawHref;
    links.add(HtmlLink(
      ref: 'L${links.length + 1}',
      text: _clip(label, 120),
      href: resolved,
    ));
  }

  final List<HtmlForm> forms = <HtmlForm>[];
  int fieldSeq = 0;
  final RegExp formRe =
      RegExp(r'<form\b([^>]*)>([\s\S]*?)</form>', caseSensitive: false);
  for (final RegExpMatch m in formRe.allMatches(cleaned)) {
    if (forms.length >= 20) break;
    final String attrs = m.group(1) ?? '';
    final String inner = m.group(2) ?? '';
    final String formRef = 'F${forms.length + 1}';
    final String method =
        (_attr(attrs, 'method') ?? 'get').toUpperCase() == 'POST'
            ? 'POST'
            : 'GET';
    final List<HtmlField> fields = <HtmlField>[];

    void addField({
      required String name,
      required String type,
      required String label,
      required String value,
      required bool hidden,
    }) {
      if (fieldSeq >= maxFields) return;
      fieldSeq++;
      fields.add(HtmlField(
        ref: 'I$fieldSeq',
        formRef: formRef,
        name: name,
        type: type,
        label: _clip(label, 80),
        value: value,
        hidden: hidden,
      ));
    }

    final RegExp inputRe =
        RegExp(r'<input\b([^>]*?)/?>', caseSensitive: false);
    for (final RegExpMatch im in inputRe.allMatches(inner)) {
      final String a = im.group(1) ?? '';
      final String type = (_attr(a, 'type') ?? 'text').toLowerCase();
      if (type == 'file' || type == 'image') continue;
      addField(
        name: (_attr(a, 'name') ?? '').trim(),
        type: type,
        label: (_attr(a, 'placeholder') ??
                _attr(a, 'aria-label') ??
                _attr(a, 'id') ??
                '')
            .trim(),
        value: (_attr(a, 'value') ?? '').trim(),
        hidden: type == 'hidden',
      );
    }

    final RegExp textareaRe =
        RegExp(r'<textarea\b([^>]*)>([\s\S]*?)</textarea>',
            caseSensitive: false);
    for (final RegExpMatch tm in textareaRe.allMatches(inner)) {
      final String a = tm.group(1) ?? '';
      addField(
        name: (_attr(a, 'name') ?? '').trim(),
        type: 'textarea',
        label: (_attr(a, 'placeholder') ?? _attr(a, 'id') ?? '').trim(),
        value: _decodeEntities(tm.group(2) ?? '').trim(),
        hidden: false,
      );
    }

    final RegExp selectRe =
        RegExp(r'<select\b([^>]*)>([\s\S]*?)</select>', caseSensitive: false);
    for (final RegExpMatch sm in selectRe.allMatches(inner)) {
      final String a = sm.group(1) ?? '';
      final String body = sm.group(2) ?? '';
      final List<RegExpMatch> options =
          RegExp(r'<option\b([^>]*)>([\s\S]*?)</option>', caseSensitive: false)
              .allMatches(body)
              .toList();
      String value = '';
      for (final RegExpMatch om in options) {
        final String oa = om.group(1) ?? '';
        final String ov = (_attr(oa, 'value') ?? _visibleText(om.group(2) ?? ''))
            .trim();
        if (om.group(1) != null &&
            RegExp(r'\bselected\b', caseSensitive: false).hasMatch(oa)) {
          value = ov;
          break;
        }
        if (value.isEmpty) value = ov;
      }
      addField(
        name: (_attr(a, 'name') ?? '').trim(),
        type: 'select',
        label: (_attr(a, 'aria-label') ?? _attr(a, 'id') ?? '').trim(),
        value: value,
        hidden: false,
      );
    }

    final RegExp buttonRe =
        RegExp(r'<button\b([^>]*)>([\s\S]*?)</button>', caseSensitive: false);
    for (final RegExpMatch bm in buttonRe.allMatches(inner)) {
      final String a = bm.group(1) ?? '';
      final String type = (_attr(a, 'type') ?? 'submit').toLowerCase();
      if (type == 'button' || type == 'reset') continue;
      addField(
        name: (_attr(a, 'name') ?? '').trim(),
        type: 'submit',
        label: _visibleText(bm.group(2) ?? ''),
        value: (_attr(a, 'value') ?? '').trim(),
        hidden: false,
      );
    }

    forms.add(HtmlForm(
      ref: formRef,
      action: (_attr(attrs, 'action') ?? '').trim(),
      method: method,
      fields: fields,
    ));
  }

  final String text = _visibleText(cleaned);
  return HtmlSnapshot(
    url: url,
    title: title,
    text: _clip(text, maxText),
    links: links,
    forms: forms,
  );
}

String _stripNonVisible(String html) {
  String out = html;
  for (final String tag in <String>[
    'script',
    'style',
    'noscript',
    'template',
    'svg',
    'canvas',
  ]) {
    out = out.replaceAll(
      RegExp('<$tag\\b[^>]*>[\\s\\S]*?</$tag>', caseSensitive: false),
      ' ',
    );
  }
  out = out.replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ');
  out = out.replaceAll(RegExp(r'<![^>]*>'), ' ');
  return out;
}

String _visibleText(String html) {
  String out = html.replaceAll(
    RegExp(
      r'<(?:br|/p|/div|/li|/tr|/h[1-6]|/section|/article|/header|/footer|/table|/ul|/ol|/form)\b[^>]*>',
      caseSensitive: false,
    ),
    '\n',
  );
  out = out.replaceAll(RegExp(r'<[^>]+>'), ' ');
  out = _decodeEntities(out);
  out = out.replaceAll('\u00a0', ' ');
  out = out.replaceAll(RegExp(r'[ \t\r\f\v]+'), ' ');
  out = out.replaceAll(RegExp(r' *\n *'), '\n');
  out = out.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return out.trim();
}

String? _resolve(Uri base, String href) {
  final Uri? parsed = Uri.tryParse(href);
  if (parsed == null) return null;
  final Uri resolved = base.hasScheme ? base.resolveUri(parsed) : parsed;
  if (resolved.scheme != 'http' && resolved.scheme != 'https') return null;
  return resolved.toString();
}

String? _firstGroup(RegExp re, String input) => re.firstMatch(input)?.group(1);

String? _attr(String attrs, String name) {
  final RegExp re = RegExp(
    '\\b$name\\s*=\\s*("([^"]*)"|\'([^\']*)\'|([^\\s>]+))',
    caseSensitive: false,
  );
  final RegExpMatch? m = re.firstMatch(attrs);
  if (m == null) return null;
  return m.group(2) ?? m.group(3) ?? m.group(4);
}

String _clip(String value, int max) {
  final String s = value.trim();
  return s.length <= max ? s : '${s.substring(0, max)}…';
}

const Map<String, String> _namedEntities = <String, String>{
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'copy': '©',
  'reg': '®',
  'trade': '™',
  'hellip': '…',
  'mdash': '—',
  'ndash': '–',
  'laquo': '«',
  'raquo': '»',
  'times': '×',
  'divide': '÷',
  'middot': '·',
  'bull': '•',
  'deg': '°',
  'euro': '€',
  'pound': '£',
  'yen': '¥',
  'cent': '¢',
  'sect': '§',
  'para': '¶',
  'plusmn': '±',
  'frac12': '½',
  'frac14': '¼',
  'frac34': '¾',
  'sup2': '²',
  'sup3': '³',
  'micro': 'µ',
};

String _decodeEntities(String input) {
  String out = input.replaceAllMapped(
    RegExp(r'&#x([0-9a-fA-F]+);'),
    (Match m) {
      final int? v = int.tryParse(m.group(1) ?? '', radix: 16);
      return v == null ? m.group(0)! : String.fromCharCode(v);
    },
  );
  out = out.replaceAllMapped(
    RegExp(r'&#([0-9]+);'),
    (Match m) {
      final int? v = int.tryParse(m.group(1) ?? '');
      return v == null ? m.group(0)! : String.fromCharCode(v);
    },
  );
  out = out.replaceAllMapped(
    RegExp(r'&([a-zA-Z][a-zA-Z0-9]{1,10});'),
    (Match m) {
      final String? v = _namedEntities[(m.group(1) ?? '').toLowerCase()];
      return v ?? m.group(0)!;
    },
  );
  return out;
}
