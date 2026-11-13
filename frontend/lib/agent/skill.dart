
import 'dart:io';

class Skill {
  Skill(
    this.name,
    this.markdown, {
    this.title,
    this.description,
    Map<String, String>? params,
  }) : params = Map.unmodifiable(params ?? const <String, String>{});

  final String name;

  final String markdown;

  final String? title;

  final String? description;

  final Map<String, String> params;

  factory Skill.fromMarkdown(String name, String markdown) {
    String? title;
    String? fmName;
    String? description;
    final params = <String, String>{};
    final lines = markdown.split('\n');
    var i = 0;

    if (lines.isNotEmpty && lines[0].trim() == '---') {
      for (i = 1; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line == '---') {
          i++;
          break;
        }
        final idx = line.indexOf(':');
        if (idx <= 0) continue;
        final key = line.substring(0, idx).trim();
        final value = line.substring(idx + 1).trim();
        if (key == 'name') {
          fmName = value;
        } else if (key == 'description') {
          description = value;
        } else if (key == 'params') {
          for (final p in value.split(RegExp(r'[,\n]'))) {
            final t = p.trim();
            if (t.isNotEmpty) params[t] = '';
          }
        } else {
          params[key] = value;
        }
      }
    }

    for (; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('# ') && title == null) {
        title = line.substring(2).trim();
        i++;
        break;
      }
    }

    if (description == null) {
      for (; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isNotEmpty && !line.startsWith('#')) {
          description = line;
          break;
        }
      }
    }

    return Skill(
      fmName ?? name,
      markdown,
      title: title,
      description: description,
      params: params,
    );
  }

  late final List<String> steps = _extractSteps();

  List<String> _extractSteps() {
    final out = <String>[];
    for (final raw in markdown.split('\n')) {
      final line = raw.trim();
      if (line.startsWith('## ') || RegExp(r'^\d+[\.\)]\s').hasMatch(line)) {
        out.add(line);
      }
    }
    return List.unmodifiable(out);
  }

  double matchScore(String query) {
    final qTokens = _tokenize(query.toLowerCase());
    if (qTokens.isEmpty) return 0.0;
    final nameText = name.toLowerCase();
    final descText = (description ?? '').toLowerCase();
    final paramText = params.keys.join(' ').toLowerCase();
    var hit = 0;
    for (final t in qTokens) {
      if (nameText.contains(t)) {
        hit += 2; // 名称命中加权
      } else if (descText.contains(t) || paramText.contains(t)) {
        hit += 1;
      }
    }
    return (hit / (qTokens.length * 2)).clamp(0.0, 1.0);
  }

  String render(Map<String, String> values) {
    return markdown.replaceAllMapped(RegExp(r'\{\{(\w+)\}\}'), (m) {
      final key = m.group(1)!;
      return values[key] ?? m.group(0)!;
    });
  }

  String run(String input, {Map<String, String>? values}) {
    final buf = StringBuffer();
    buf.writeln('[skill:$name]');
    if (title != null) buf.writeln('title: $title');
    if (description != null) buf.writeln('description: $description');
    buf.writeln('input: $input');
    if (values != null && values.isNotEmpty) {
      buf.writeln('params:');
      values.forEach((k, v) => buf.writeln('  - $k = $v'));
    }
    if (steps.isNotEmpty) {
      buf.writeln('steps:');
      for (final s in steps) buf.writeln('  - $s');
    }
    buf.writeln('[skill:$name] done');
    return buf.toString();
  }

  static List<String> _tokenize(String text) =>
      text.split(RegExp(r'[\s_\-/]+')).where((t) => t.isNotEmpty).toList();
}

class SkillRegistry {
  final Map<String, Skill> _skills = <String, Skill>{};

  void loadFromDir(Directory dir) {
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('SKILL.md')) {
        final name = entity.parent.uri.pathSegments
            .where((s) => s.isNotEmpty)
            .last;
        final skill = Skill.fromMarkdown(name, entity.readAsStringSync());
        _skills[skill.name] = skill;
      }
    }
  }

  void register(Skill skill) => _skills[skill.name] = skill;

  Skill? lookup(String name) => _skills[name];

  List<Skill> match(String query, {int k = 5}) {
    final scored =
        _skills.values
            .map((s) => MapEntry(s, s.matchScore(query)))
            .where((e) => e.value > 0)
            .toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    return scored.take(k).map((e) => e.key).toList(growable: false);
  }

  String run(String skillName, String input) {
    final skill = _skills[skillName];
    if (skill == null) return '[skill:$skillName] 未注册';
    return skill.run(input);
  }

  List<String> get names => _skills.keys.toList(growable: false);

  int get count => _skills.length;
}
