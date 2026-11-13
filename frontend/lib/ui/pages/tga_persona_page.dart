import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../bridge/bridge_protocol.dart';
import '../../design/tga_design.dart';
import '../../services/persona_store.dart';
import '../../services/task_scheduler.dart';

/// 人格设置（2026-11-13 真实化）：
/// - 头像：默认内置 TGA 鹿标，点击经 image_picker 选图并复制到应用文档目录，
///   路径存 [PersonaStore.avatarPath]，全局生效；支持恢复默认。
/// - AI 名字：铅笔改名，存 [PersonaStore.aiName]（默认 TGA）。
/// - 人格列表：多套人格真实持久化，点选切换、长按删除/重置（最后一条只重置）。
/// - 人设管理：身份/个性/为谁服务 三段各自可编辑保存，保存后组装进系统提示词，
///   真实影响后续对话。
/// - 我的日记：数据来自后端 memory_event diary（真实对话记录按天分组），
///   支持范围/月历筛选、详情页与按天删除。
/// - 定时任务：数据来自后端 proactive_task，标题约定「任务名 @HH:mm」，
///   由 [TaskScheduler] 每 30 秒轮询、到点经 chat 真实执行。
class TgaPersonaPage extends StatelessWidget {
  const TgaPersonaPage({super.key});

  @override
  Widget build(BuildContext context) {
    final PersonaStore store = context.watch<PersonaStore>();
    final BackendClient backend = context.read<BackendClient>();
    final bool lastPersona = store.personas.length <= 1;
    return TgaPage(
      title: '人格设置',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 8, Tga.pagePad, 40),
        children: <Widget>[
          // ---------- 头像 + AI 名字 ----------
          Center(
            child: Column(
              children: <Widget>[
                _Avatar(store: store),
                const SizedBox(height: 6),
                if (store.avatarPath != null)
                  TgaButton(
                    label: '恢复默认头像',
                    color: Tga.textSub,
                    filled: false,
                    onTap: () => store.setAvatarPath(null),
                  ),
                const SizedBox(height: 8),
                // 页面标题区显示 aiName（默认 TGA），铅笔改名真实落盘。
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Flexible(child: Text(store.aiName, style: Tga.h1)),
                    IconButton(
                      tooltip: '修改 AI 名字',
                      icon: Icon(Icons.edit_outlined,
                          size: 16, color: Tga.textSub),
                      onPressed: () async {
                        final String? name = await _promptText(
                          context,
                          title: '修改 AI 名字',
                          initial: store.aiName,
                          hint: '例如 TGA / cosmo',
                        );
                        if (name != null && name.isNotEmpty) {
                          store.setAiName(name);
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(store.activePersona.name, style: Tga.sub),
              ],
            ),
          ),

          // ---------- 人格列表 ----------
          TgaGroupTitle(
            '人格列表',
            trailing: IconButton(
              tooltip: '新建人格',
              icon: Icon(Icons.add_rounded,
                  size: 20, color: Tga.primary),
              onPressed: () async {
                final String? name = await _promptText(
                  context,
                  title: '新建人格',
                  initial: '',
                  hint: '给这套人格起个名字',
                );
                if (name != null && name.isNotEmpty) {
                  store.addPersona(name);
                  if (!context.mounted) return;
                  _toast(context, '已创建人格「$name」');
                }
              },
            ),
          ),
          TgaCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: <Widget>[
                for (int i = 0; i < store.personas.length; i++) ...<Widget>[
                  if (i > 0) const TgaTileDivider(),
                  GestureDetector(
                    // 长按：多于一条真删除，只剩最后一条改为重置为默认设定。
                    onLongPress: () => _onPersonaLongPress(
                        context, backend, store, store.personas[i]),
                    child: TgaIconTile(
                      icon: store.personas[i].id == store.activePersonaId
                          ? Icons.face_retouching_natural_rounded
                          : Icons.face_retouching_natural_outlined,
                      title: store.personas[i].name,
                      subtitle: store.personas[i].id == store.activePersonaId
                          ? '当前人格 · 长按可删除/重置'
                          : '点选切换 · 长按可删除',
                      showArrow: false,
                      trailing: store.personas[i].id == store.activePersonaId
                          ? Icon(Icons.check_circle_rounded,
                              size: 18, color: Tga.green)
                          : null,
                      onTap: () => store.setActivePersonaId(store.personas[i].id),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // ---------- 人设管理入口 ----------
          const TgaGroupTitle('人设管理'),
          TgaCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: <Widget>[
                TgaIconTile(
                  icon: Icons.badge_outlined,
                  title: '身份设置',
                  subtitle: '编辑身份 / 个性 / 为谁服务，保存后真实生效',
                  onTap: () => _push(context, const _IdentitySubPage()),
                ),
                const TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.menu_book_outlined,
                  iconBg: Tga.iconPurpleBg,
                  iconColor: Tga.iconPurple,
                  title: '我的日记',
                  subtitle: '来自真实对话记录 · 按天查看',
                  onTap: () => _push(context, const _DiarySubPage()),
                ),
                const TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.schedule_rounded,
                  iconBg: Tga.iconCyanBg,
                  iconColor: Tga.iconCyan,
                  title: '定时任务',
                  subtitle: '每日 HH:mm 到点自动执行并写入对话记录',
                  onTap: () => _push(context, const _ScheduleSubPage()),
                ),
              ],
            ),
          ),

          // ---------- 删除 / 重置伙伴 ----------
          const SizedBox(height: 26),
          Center(
            child: GestureDetector(
              onTap: () => lastPersona
                  ? _confirmResetCompanion(context, backend, store)
                  : _confirmDeletePersona(
                      context, store, store.activePersona),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 28, vertical: 11),
                decoration: BoxDecoration(
                  color: Tga.iconRedBg,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Text(lastPersona ? '重置伙伴' : '删除伙伴',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Tga.red)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (BuildContext _) => page),
    );
  }

  /// 长按某条人格：多于一条 → 真删除；只剩最后一条 → 重置为默认人格设定。
  Future<void> _onPersonaLongPress(BuildContext context,
      BackendClient backend, PersonaStore store, Persona p) async {
    if (store.personas.length > 1) {
      await _confirmDeletePersona(context, store, p);
    } else {
      await _confirmResetCompanion(context, backend, store);
    }
  }

  Future<void> _confirmDeletePersona(
      BuildContext context, PersonaStore store, Persona p) async {
    final bool ok = await _confirm(
      context,
      title: '删除人格「${p.name}」',
      message: '删除后不可恢复；若删除的是当前人格，会自动切换到剩余人格。',
      okLabel: '删除',
    );
    if (!ok) return;
    store.removePersona(p.id);
    if (!context.mounted) return;
    _toast(context, '已删除人格「${p.name}」，当前人格：${store.activePersona.name}');
  }

  /// 重置伙伴：人格文案恢复默认 + 全部定时任务真实删除 + 日记逐日真实删除。
  Future<void> _confirmResetCompanion(
      BuildContext context, BackendClient backend, PersonaStore store) async {
    final bool ok = await _confirm(
      context,
      title: '重置伙伴',
      message: '这是最后一个人格，不能删除。将重置为默认人格设定，'
          '并真实清空全部定时任务与我的日记，不可恢复。',
      okLabel: '重置',
    );
    if (!ok) return;
    store.resetActivePersona();
    try {
      // 定时任务：逐条真实删除。
      final BridgeEnvelope list = await backend.sendControl(
          'proactive_task', <String, dynamic>{'action': 'list'});
      final dynamic payload = list.payload;
      if (payload is Map && payload['rules'] is List) {
        for (final dynamic r in payload['rules'] as List<dynamic>) {
          if (r is Map && r['id'] != null) {
            await backend.sendControl('proactive_task',
                <String, dynamic>{'action': 'delete', 'id': r['id']});
          }
        }
      }
      // 日记：逐日真实删除。
      final BridgeEnvelope diary = await backend.sendControl(
          'memory_event', <String, dynamic>{'action': 'diary'});
      final dynamic dp = diary.payload;
      if (dp is Map && dp['days'] is List) {
        for (final dynamic d in dp['days'] as List<dynamic>) {
          if (d is Map && d['day'] != null) {
            await backend.sendControl('memory_event', <String, dynamic>{
              'action': 'delete_day',
              'day': d['day'].toString(),
            });
          }
        }
      }
      if (!context.mounted) return;
      _toast(context, '已重置，历史已清空');
    } on Object catch (e) {
      if (!context.mounted) return;
      _toast(context, '人格已重置，但历史清空失败：$e');
    }
  }
}

// ---------------------------------------------------------------------------
// 头像：默认内置鹿标；点击选图 → 复制到应用文档目录 → 路径存 PersonaStore
// ---------------------------------------------------------------------------
class _Avatar extends StatelessWidget {
  const _Avatar({required this.store});
  final PersonaStore store;

  @override
  Widget build(BuildContext context) {
    final String? path = store.avatarPath;
    // 仅当自定义头像文件真实存在时才使用，否则回退内置鹿标。
    final File? custom = (path != null && File(path).existsSync())
        ? File(path)
        : null;
    return GestureDetector(
      onTap: () => _pick(context),
      child: Container(
        width: 88,
        height: 88,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: <Color>[Tga.iconBlue, Tga.iconCyan],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          shape: BoxShape.circle,
        ),
        clipBehavior: Clip.antiAlias,
        child: custom != null
            ? Image.file(
                custom,
                width: 88,
                height: 88,
                fit: BoxFit.cover,
                // 文件损坏时如实回退到内置鹿标，不空白。
                errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
                    _defaultLogo(),
              )
            : _defaultLogo(),
      ),
    );
  }

  /// 默认头像：内置 TGA 鹿标资源。
  Widget _defaultLogo() => Image.asset(
        'assets/logo/tangram_deer_192.png',
        width: 88,
        height: 88,
        fit: BoxFit.cover,
        errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
            Icon(Icons.smart_toy_rounded, size: 40, color: Tga.onPrimary),
      );

  Future<void> _pick(BuildContext context) async {
    try {
      final XFile? picked =
          await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      final Directory docs = await getApplicationDocumentsDirectory();
      final Directory dir = Directory('${docs.path}/persona');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final List<String> segs = picked.path.split('.');
      final String ext = segs.length > 1 ? segs.last : 'jpg';
      final File target = File('${dir.path}/avatar.$ext');
      await File(picked.path).copy(target.path);
      store.setAvatarPath(target.path);
      if (!context.mounted) return;
      _toast(context, '头像已更新，全局生效');
    } on Object catch (e) {
      if (!context.mounted) return;
      _toast(context, '头像设置失败：$e');
    }
  }
}

// ---------------------------------------------------------------------------
// 子页 1：人设管理（身份 / 个性 / 为谁服务 分段，各自可编辑并真实保存）
// ---------------------------------------------------------------------------
class _IdentitySubPage extends StatefulWidget {
  const _IdentitySubPage();
  @override
  State<_IdentitySubPage> createState() => _IdentitySubPageState();
}

class _IdentitySubPageState extends State<_IdentitySubPage> {
  static const List<String> _tabs = <String>['身份设定', '个性设定', '为谁服务'];
  static const List<String> _files = <String>[
    'IDENTITY.md',
    'PERSONALITY.md',
    'AUDIENCE.md',
  ];
  int _tab = 0;
  late final List<TextEditingController> _controllers;

  @override
  void initState() {
    super.initState();
    // 三个标签各自一份可编辑文案，初值来自当前激活人格的真实设定。
    final Persona p = context.read<PersonaStore>().activePersona;
    _controllers = <TextEditingController>[
      TextEditingController(text: p.identity),
      TextEditingController(text: p.personality),
      TextEditingController(text: p.audience),
    ];
  }

  @override
  void dispose() {
    for (final TextEditingController c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final PersonaStore store = context.watch<PersonaStore>();
    return TgaPage(
      title: '人设管理',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 40),
        children: <Widget>[
          TgaSegmented<String>(
            items: _tabs,
            value: _tabs[_tab],
            labelOf: (String s) => s,
            onChanged: (String v) => setState(() => _tab = _tabs.indexOf(v)),
          ),
          const SizedBox(height: 4),
          Text('当前人格：${store.activePersona.name}', style: Tga.sub),
          const TgaGroupTitle('IDENTITY'),
          TgaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(Icons.badge_outlined,
                        size: 18, color: Tga.primary),
                    const SizedBox(width: 8),
                    Text(_files[_tab], style: Tga.body),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: Tga.cardAlt,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Tga.border),
                  ),
                  child: TextField(
                    controller: _controllers[_tab],
                    minLines: 8,
                    maxLines: null,
                    keyboardType: TextInputType.multiline,
                    style: Tga.body.copyWith(fontSize: 13),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      isCollapsed: true,
                      hintText: _hintFor(_tabs[_tab]),
                      hintStyle: Tga.sub,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerRight,
                  child: TgaButton(
                    label: '保存',
                    icon: Icons.check_rounded,
                    onTap: _save,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          TgaCard(
            child: Text(_hintFor(_tabs[_tab]), style: Tga.sub),
          ),
        ],
      ),
    );
  }

  /// 保存当前标签到激活人格，并同步系统提示词（真实影响后续对话）。
  void _save() {
    final PersonaStore store = context.read<PersonaStore>();
    final String text = _controllers[_tab].text;
    switch (_tab) {
      case 0:
        store.updateActivePersona(identity: text);
      case 1:
        store.updateActivePersona(personality: text);
      default:
        store.updateActivePersona(audience: text);
    }
    _toast(context, '已保存「${_tabs[_tab]}」，将应用于后续对话');
  }

  String _hintFor(String tab) {
    switch (tab) {
      case '身份设定':
        return '定义「它是谁」：名字、角色定位、核心信条、能力边界。';
      case '个性设定':
        return '定义「怎么说话」：语气风格、表达节奏、主动性、幽默度。';
      default:
        return '定义「为谁工作」：服务对象、使用场景、偏好与禁忌。';
    }
  }
}

// ---------------------------------------------------------------------------
// 子页 2：我的日记（真实 memory_event diary + 范围/月历筛选 + 详情/删除）
// ---------------------------------------------------------------------------

/// 一条真实对话记录（来自后端 turns）。
class _DiaryEntry {
  const _DiaryEntry(
      {required this.role, required this.text, required this.ts});
  final String role;
  final String text;
  final double ts; // 秒级时间戳（后端 _now()）
}

/// 按天分组后的日记。
class _DiaryDay {
  const _DiaryDay({required this.day, required this.entries});
  final String day; // YYYY-MM-DD
  final List<_DiaryEntry> entries; // 已按时间升序
}

class _DiarySubPage extends StatefulWidget {
  const _DiarySubPage();
  @override
  State<_DiarySubPage> createState() => _DiarySubPageState();
}

class _DiarySubPageState extends State<_DiarySubPage> {
  static const List<String> _rangeLabels = <String>['最近一周', '最近一个月', '全部'];
  int _range = 2; // 默认全部
  String? _pinnedDay; // 月历里点选的某天（只看那天）
  bool _calendarOpen = false;
  late DateTime _month; // 月历当前展示的月份
  List<_DiaryDay> _days = const <_DiaryDay>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final DateTime now = DateTime.now();
    _month = DateTime(now.year, now.month);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final BackendClient backend = context.read<BackendClient>();
      final BridgeEnvelope env = await backend.sendControl(
          'memory_event', <String, dynamic>{'action': 'diary'});
      final dynamic payload = env.payload;
      if (payload is! Map || payload['days'] is! List) {
        throw StateError('后端返回了非预期结构');
      }
      final List<_DiaryDay> days = <_DiaryDay>[];
      for (final dynamic d in payload['days'] as List<dynamic>) {
        if (d is! Map) continue;
        final List<_DiaryEntry> entries = <_DiaryEntry>[];
        final dynamic rawEntries = d['entries'];
        if (rawEntries is List) {
          for (final dynamic e in rawEntries) {
            if (e is! Map) continue;
            entries.add(_DiaryEntry(
              role: (e['role'] ?? 'user').toString(),
              text: (e['text'] ?? '').toString(),
              ts: e['ts'] is num ? (e['ts'] as num).toDouble() : 0,
            ));
          }
        }
        entries.sort((_DiaryEntry a, _DiaryEntry b) => a.ts.compareTo(b.ts));
        days.add(_DiaryDay(day: (d['day'] ?? '').toString(), entries: entries));
      }
      days.sort((_DiaryDay a, _DiaryDay b) => b.day.compareTo(a.day));
      if (!mounted) return;
      setState(() {
        _days = days;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// 按范围 / 点选某天过滤后的日记。
  List<_DiaryDay> _filtered() {
    if (_pinnedDay != null) {
      return _days.where((_DiaryDay d) => d.day == _pinnedDay).toList();
    }
    if (_range == 2) return _days;
    final DateTime now = DateTime.now();
    final int keep = _range == 0 ? 7 : 30;
    final String cutoff = _dayKey(now.subtract(Duration(days: keep - 1)));
    return _days.where((_DiaryDay d) => d.day.compareTo(cutoff) >= 0).toList();
  }

  @override
  Widget build(BuildContext context) {
    final PersonaStore store = context.watch<PersonaStore>();
    final List<_DiaryDay> shown = _filtered();
    return TgaPage(
      title: '我的日记',
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TgaSegmented<int>(
                        items: const <int>[0, 1, 2],
                        value: _range,
                        labelOf: (int i) => _rangeLabels[i],
                        onChanged: (int v) => setState(() {
                          _range = v;
                          _pinnedDay = null;
                        }),
                      ),
                    ),
                    TgaButton(
                      label: _calendarOpen ? '收起月历' : '月历',
                      icon: Icons.calendar_month_rounded,
                      color: _calendarOpen ? Tga.primary : Tga.textSub,
                      filled: _calendarOpen,
                      onTap: () => setState(() => _calendarOpen = !_calendarOpen),
                    ),
                  ],
                ),
                if (_pinnedDay != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: GestureDetector(
                      // 点选某天后只看那天；再点一下清除日期筛选。
                      onTap: () => setState(() => _pinnedDay = null),
                      child: TgaTag('只看 ${_shortDay(_pinnedDay!)} ✕',
                          color: Tga.purple, filled: true),
                    ),
                  ),
                if (_calendarOpen) _calendar(),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? Center(
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Tga.primary)))
                : _error != null
                    ? TgaEmpty('日记读取失败：$_error',
                        icon: Icons.error_outline_rounded)
                    : shown.isEmpty
                        ? TgaEmpty('还没有日记，先和 ${store.aiName} 聊聊天',
                            icon: Icons.menu_book_outlined)
                        : GridView.builder(
                            padding: const EdgeInsets.all(Tga.pagePad),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                              childAspectRatio: 0.92,
                            ),
                            itemCount: shown.length,
                            itemBuilder: (BuildContext context, int i) =>
                                _diaryCard(shown[i], store.aiName),
                          ),
          ),
        ],
      ),
    );
  }

  Widget _diaryCard(_DiaryDay day, String aiName) {
    final String summary = day.entries.isEmpty
        ? '（无内容）'
        : _roleLabel(day.entries.first.role, aiName) +
            '：${day.entries.first.text}';
    return TgaCard(
      padding: const EdgeInsets.all(13),
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute<bool>(
          builder: (BuildContext _) => _DiaryDayPage(day: day, aiName: aiName),
        ));
        if (!mounted) return;
        _load(); // 详情页可能删除了整天，回来重新拉取真实数据
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              TgaTag(_shortDay(day.day), color: Tga.primary),
              const Spacer(),
              TgaTag('${day.entries.length} 条', color: Tga.cyan),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Text(summary,
                style: Tga.sub, maxLines: 6, overflow: TextOverflow.ellipsis),
          ),
          Align(
            alignment: Alignment.bottomLeft,
            child: Text('偷看',
                style: TextStyle(
                    fontSize: 11.5,
                    color: Tga.primary,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  /// 可展开月历：有日记的日期带圆点，点某天只看那天。
  Widget _calendar() {
    final Set<String> withEntries = _days.map((_DiaryDay d) => d.day).toSet();
    final DateTime today = DateTime.now();
    final DateTime first = DateTime(_month.year, _month.month, 1);
    final int daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final int leading = first.weekday % 7; // 周日开头
    final List<String> weekdays = const <String>[
      '日', '一', '二', '三', '四', '五', '六'
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: TgaCard(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                IconButton(
                  icon: Icon(Icons.chevron_left_rounded,
                      size: 20, color: Tga.primary),
                  onPressed: () => setState(() => _month =
                      DateTime(_month.year, _month.month - 1)),
                ),
                Text('${_month.year} 年 ${_month.month} 月', style: Tga.body),
                IconButton(
                  icon: Icon(Icons.chevron_right_rounded,
                      size: 20, color: Tga.primary),
                  onPressed: () => setState(() => _month =
                      DateTime(_month.year, _month.month + 1)),
                ),
              ],
            ),
            Row(
              children: <Widget>[
                for (final String w in weekdays)
                  Expanded(
                    child: Center(child: Text(w, style: Tga.caption)),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7, childAspectRatio: 1.0),
              itemCount: leading + daysInMonth,
              itemBuilder: (BuildContext context, int i) {
                if (i < leading) return const SizedBox.shrink();
                final int d = i - leading + 1;
                final String key = _dayKey(DateTime(_month.year, _month.month, d));
                final bool selected = _pinnedDay == key;
                final bool isToday = key == _dayKey(today);
                return GestureDetector(
                  onTap: () => setState(() =>
                      _pinnedDay = selected ? null : key),
                  child: Container(
                    margin: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: selected ? Tga.primary : null,
                      shape: BoxShape.circle,
                      border: isToday && !selected
                          ? Border.all(color: Tga.primary, width: 1.2)
                          : null,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Text('$d',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: selected
                                    ? Tga.onPrimary
                                    : Tga.text)),
                        Container(
                          width: 4,
                          height: 4,
                          margin: const EdgeInsets.only(top: 1),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: withEntries.contains(key)
                                ? (selected ? Tga.onPrimary : Tga.cyan)
                                : Colors.transparent,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  static String _dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static String _shortDay(String day) =>
      day.length >= 10 ? day.substring(5) : day; // MM-DD
}

/// 某天日记详情：按时间排列全部条目，支持删除该天。
class _DiaryDayPage extends StatelessWidget {
  const _DiaryDayPage({required this.day, required this.aiName});
  final _DiaryDay day;
  final String aiName;

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: '${day.day} 的日记',
      actions: <Widget>[
        IconButton(
          tooltip: '删除这一天',
          icon: Icon(Icons.delete_outline_rounded,
              size: 20, color: Tga.red),
          onPressed: () async {
            final bool ok = await _confirm(context,
                title: '删除 ${day.day} 的日记',
                message: '将真实删除该天全部对话记录（共 ${day.entries.length} 条），不可恢复。',
                okLabel: '删除');
            if (!ok) return;
            if (!context.mounted) return;
            try {
              final BackendClient backend = context.read<BackendClient>();
              await backend.sendControl('memory_event',
                  <String, dynamic>{'action': 'delete_day', 'day': day.day});
              if (!context.mounted) return;
              Navigator.of(context).pop(true);
            } on Object catch (e) {
              if (!context.mounted) return;
              _toast(context, '删除失败：$e');
            }
          },
        ),
      ],
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 40),
        itemCount: day.entries.length,
        separatorBuilder: (BuildContext _, int __) => const SizedBox(height: 10),
        itemBuilder: (BuildContext context, int i) {
          final _DiaryEntry e = day.entries[i];
          final DateTime t =
              DateTime.fromMillisecondsSinceEpoch((e.ts * 1000).round());
          final bool mine = e.role == 'user';
          return TgaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    TgaTag(_roleLabel(e.role, aiName),
                        color: mine ? Tga.primary : Tga.cyan, filled: true),
                    const SizedBox(width: 8),
                    Text(
                        '${t.hour.toString().padLeft(2, '0')}:'
                        '${t.minute.toString().padLeft(2, '0')}',
                        style: Tga.caption),
                  ],
                ),
                const SizedBox(height: 8),
                Text(e.text, style: Tga.body),
              ],
            ),
          );
        },
      ),
    );
  }
}

String _roleLabel(String role, String aiName) {
  switch (role) {
    case 'user':
      return '我';
    case 'assistant':
      return aiName;
    case 'memory':
      return '记忆';
    default:
      return role;
  }
}

// ---------------------------------------------------------------------------
// 子页 3：定时任务（真实 proactive_task + 到点由 TaskScheduler 真实执行）
//
// 任务列表下方有「最近执行」区块：TaskScheduler 到点执行的真实结果写在
// memory_event diary（session_id=='proactive' 的 assistant 回复），
// 这里拉取、过滤、按时间倒序取最近 10 条展示；点击行内展开全文。
// ---------------------------------------------------------------------------

/// 一条已解析的定时任务规则。
class _TaskRule {
  const _TaskRule({
    required this.id,
    required this.title,
    required this.name,
    required this.enabled,
    this.scheduled,
  });
  final int id;
  final String title; // 后端原始标题（含 @HH:mm 与说明）
  final String name; // 展示名
  final bool enabled;
  final ParsedTask? scheduled; // 解析出的每日时间；null 表示不会被自动执行
}

/// 一条定时任务真实执行结果（diary 中 session_id=='proactive' 的 assistant 输出）。
class _ExecRecord {
  const _ExecRecord({required this.day, required this.ts, required this.text});
  final String day; // YYYY-MM-DD
  final double ts; // 秒级时间戳
  final String text; // 任务输出全文
}

class _ScheduleSubPage extends StatefulWidget {
  const _ScheduleSubPage();
  @override
  State<_ScheduleSubPage> createState() => _ScheduleSubPageState();
}

class _ScheduleSubPageState extends State<_ScheduleSubPage> {
  List<_TaskRule> _rules = const <_TaskRule>[];
  bool _loading = true;
  String? _error;

  // 「最近执行」区块：diary 中 session_id=='proactive' 的真实执行结果。
  List<_ExecRecord> _execs = const <_ExecRecord>[];
  String? _execError;
  final Set<int> _expanded = <int>{}; // 行内展开的条目下标

  @override
  void initState() {
    super.initState();
    _load(showSpinner: true);
    _loadExecs();
  }

  Future<void> _load({bool showSpinner = false}) async {
    if (showSpinner) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final BackendClient backend = context.read<BackendClient>();
      final BridgeEnvelope env = await backend.sendControl(
          'proactive_task', <String, dynamic>{'action': 'list'});
      final dynamic payload = env.payload;
      if (payload is! Map || payload['rules'] is! List) {
        throw StateError('后端返回了非预期结构');
      }
      final List<_TaskRule> rules = <_TaskRule>[];
      for (final dynamic r in payload['rules'] as List<dynamic>) {
        if (r is! Map) continue;
        final String title = (r['title'] ?? r['name'] ?? '').toString();
        rules.add(_TaskRule(
          id: r['id'] is num ? (r['id'] as num).toInt() : 0,
          title: title,
          name: title.split('\n').first,
          enabled: r['enabled'] == true,
          scheduled: TaskScheduler.parseTitle(title),
        ));
      }
      if (!mounted) return;
      setState(() {
        _rules = rules;
        _loading = false;
        _error = null;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// 拉取定时任务真实执行结果：memory_event diary，
  /// 过滤 session_id=='proactive' 的 assistant 输出，按时间倒序取最近 10 条。
  Future<void> _loadExecs() async {
    try {
      final BackendClient backend = context.read<BackendClient>();
      final BridgeEnvelope env = await backend.sendControl(
          'memory_event', <String, dynamic>{'action': 'diary'});
      final dynamic payload = env.payload;
      if (payload is! Map || payload['days'] is! List) {
        throw StateError('后端返回了非预期结构');
      }
      final List<_ExecRecord> execs = <_ExecRecord>[];
      for (final dynamic d in payload['days'] as List<dynamic>) {
        if (d is! Map) continue;
        final String day = (d['day'] ?? '').toString();
        final dynamic rawEntries = d['entries'];
        if (rawEntries is! List) continue;
        for (final dynamic e in rawEntries) {
          if (e is! Map) continue;
          if ((e['session_id'] ?? '').toString() != 'proactive') continue;
          if ((e['role'] ?? '').toString() != 'assistant') continue;
          final String text = (e['text'] ?? '').toString();
          if (text.isEmpty) continue;
          execs.add(_ExecRecord(
            day: day,
            ts: e['ts'] is num ? (e['ts'] as num).toDouble() : 0,
            text: text,
          ));
        }
      }
      execs.sort((_ExecRecord a, _ExecRecord b) => b.ts.compareTo(a.ts));
      if (!mounted) return;
      setState(() {
        _execs = execs.take(10).toList();
        _execError = null;
        _expanded.clear();
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _execError = '$e');
    }
  }

  /// 下拉刷新：任务列表与最近执行一起重拉（不整页转圈）。
  Future<void> _refresh() async {
    await _load();
    await _loadExecs();
  }

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    final PersonaStore store = context.watch<PersonaStore>();
    return Scaffold(
      // 与 TgaPage 同款视觉，额外提供右下角悬浮「+」新建任务。
      backgroundColor: Tga.bg,
      appBar: AppBar(
        backgroundColor: Tga.bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        title: Text('定时任务', style: Tga.h1),
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: '新建定时任务',
        backgroundColor: Tga.primary,
        onPressed: () async {
          await Navigator.of(context).push(MaterialPageRoute<bool>(
            builder: (BuildContext _) => const _TaskEditPage(),
          ));
          if (!mounted) return;
          _load();
        },
        child: Icon(Icons.add_rounded, color: Tga.onPrimary),
      ),
      body: SafeArea(
        child: _loading
            ? Center(
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Tga.primary)))
            : _error != null
                ? TgaEmpty('任务读取失败：$_error',
                    icon: Icons.error_outline_rounded)
                : _rules.isEmpty
                    ? RefreshIndicator(
                        onRefresh: _refresh,
                        child: ListView(
                          padding: const EdgeInsets.all(Tga.pagePad),
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: <Widget>[
                            const TgaEmpty('还没有定时任务，点右下角「+」新建一条',
                                icon: Icons.schedule_rounded),
                            const SizedBox(height: 10),
                            TgaCard(
                              child: Text(
                                '任务按标题里的「@HH:mm」每天执行一次：到点后 ${store.aiName} '
                                '会经对话链路真实执行，结果写入对话记录'
                                '（可在「我的日记」与下方「最近执行」查看）。',
                                style: Tga.sub,
                              ),
                            ),
                            _recentExecSection(),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _refresh,
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(
                              Tga.pagePad, 6, Tga.pagePad, 80),
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: <Widget>[
                            TgaCard(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Column(
                                children: <Widget>[
                                  for (int i = 0; i < _rules.length;
                                      i++) ...<Widget>[
                                    if (i > 0) const TgaTileDivider(),
                                    TgaIconTile(
                                      icon: _rules[i].scheduled != null &&
                                              _rules[i].scheduled!.hour < 12
                                          ? Icons.wb_sunny_outlined
                                          : Icons.nightlight_outlined,
                                      iconBg: _rules[i].enabled
                                          ? Tga.iconGoldBg
                                          : Tga.divider,
                                      iconColor: _rules[i].enabled
                                          ? Tga.iconGold
                                          : Tga.textDim,
                                      title: _rules[i].scheduled?.name ??
                                          _rules[i].name,
                                      subtitle: _subtitleFor(_rules[i], store),
                                      showArrow: true,
                                      trailing: TgaTag(
                                          _rules[i].enabled ? '已启用' : '已停用',
                                          color: _rules[i].enabled
                                              ? Tga.green
                                              : Tga.textDim),
                                      onTap: () async {
                                        await Navigator.of(context).push(
                                          MaterialPageRoute<bool>(
                                            builder: (BuildContext _) =>
                                                _TaskEditPage(rule: _rules[i]),
                                          ),
                                        );
                                        if (!mounted) return;
                                        _load();
                                      },
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            _recentExecSection(),
                          ],
                        ),
                      ),
      ),
    );
  }

  String _subtitleFor(_TaskRule r, PersonaStore store) {
    final ParsedTask? s = r.scheduled;
    if (s == null) return '未设置每日时间 · 不会被自动执行';
    final String? last = store.taskLastRun['${r.id}'];
    final String desc = s.description.isEmpty ? '' : ' · ${s.description}';
    return '${s.timeLabel} 每天$desc · 上次执行：${last ?? '尚未执行'}';
  }

  /// 「最近执行」区块：TaskScheduler 到点执行的真实结果
  /// （diary 中 session_id=='proactive'，按时间倒序最近 10 条）。
  Widget _recentExecSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const TgaGroupTitle('最近执行'),
        TgaCard(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: _execError != null
              ? Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.error_outline_rounded,
                          size: 16, color: Tga.red),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text('执行记录读取失败：$_execError',
                              style: Tga.sub)),
                      TextButton(
                          onPressed: _loadExecs, child: const Text('重试')),
                    ],
                  ),
                )
              : _execs.isEmpty
                  ? const TgaEmpty(
                      '还没有执行记录，任务到点后结果会出现在这里',
                      icon: Icons.hourglass_empty_rounded)
                  : Column(
                      children: <Widget>[
                        for (int i = 0; i < _execs.length; i++) ...<Widget>[
                          if (i > 0) const TgaTileDivider(),
                          _execTile(_execs[i], i),
                        ],
                      ],
                    ),
        ),
      ],
    );
  }

  /// 单条执行结果：日期时间 + 输出摘要，点击行内展开全文。
  Widget _execTile(_ExecRecord r, int index) {
    final bool open = _expanded.contains(index);
    return InkWell(
      onTap: () => setState(() {
        if (open) {
          _expanded.remove(index);
        } else {
          _expanded.add(index);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.check_circle_outline_rounded,
                    size: 15, color: Tga.green),
                const SizedBox(width: 6),
                Text(_fmtExecTime(r.ts), style: Tga.caption),
                const Spacer(),
                Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    size: 16, color: Tga.textDim),
              ],
            ),
            const SizedBox(height: 6),
            Text(r.text,
                style: Tga.sub,
                maxLines: open ? null : 2,
                overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }

  /// 秒级时间戳 → 「MM-dd HH:mm」本地时间展示。
  static String _fmtExecTime(double tsSeconds) {
    if (tsSeconds <= 0) return '时间未知';
    final DateTime t =
        DateTime.fromMillisecondsSinceEpoch((tsSeconds * 1000).round());
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}

/// 新建 / 编辑定时任务表单页。rule == null 表示新建。
///
/// 后端 proactive_task 只支持 add/toggle/delete/set_rule（无改名接口），
/// 因此「改名/改时间/改说明」= 删除旧规则 + 按约定标题重建，并如实恢复开关。
class _TaskEditPage extends StatefulWidget {
  const _TaskEditPage({this.rule});
  final _TaskRule? rule;
  @override
  State<_TaskEditPage> createState() => _TaskEditPageState();
}

class _TaskEditPageState extends State<_TaskEditPage> {
  late final TextEditingController _name;
  late final TextEditingController _desc;
  late TimeOfDay _time;
  late bool _enabled;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final _TaskRule? r = widget.rule;
    final ParsedTask? s = r?.scheduled;
    _name = TextEditingController(text: s?.name ?? r?.name ?? '');
    _desc = TextEditingController(text: s?.description ?? '');
    _time = s != null
        ? TimeOfDay(hour: s.hour, minute: s.minute)
        : const TimeOfDay(hour: 9, minute: 0);
    _enabled = r?.enabled ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  String get _timeLabel =>
      '${_time.hour.toString().padLeft(2, '0')}:'
      '${_time.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final bool isNew = widget.rule == null;
    return TgaPage(
      title: isNew ? '新建定时任务' : '编辑定时任务',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 40),
        children: <Widget>[
          const TgaGroupTitle('任务'),
          TgaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('任务名', style: Tga.body),
                const SizedBox(height: 6),
                TextField(
                  controller: _name,
                  style: Tga.body,
                  decoration: const InputDecoration(
                    hintText: '例如：每日晨间简报',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    Expanded(child: Text('每日执行时间', style: Tga.body)),
                    TgaButton(
                      label: _timeLabel,
                      icon: Icons.schedule_rounded,
                      color: Tga.primary,
                      filled: false,
                      onTap: () async {
                        final TimeOfDay? t = await showTimePicker(
                            context: context, initialTime: _time);
                        if (t != null) setState(() => _time = t);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text('说明（会随任务一起执行）', style: Tga.body),
                const SizedBox(height: 6),
                TextField(
                  controller: _desc,
                  minLines: 3,
                  maxLines: 6,
                  keyboardType: TextInputType.multiline,
                  style: Tga.body,
                  decoration: const InputDecoration(
                    hintText: '例如：汇总昨日记忆与今日待办，发一份简报',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                if (!isNew) ...<Widget>[
                  const SizedBox(height: 14),
                  Row(
                    children: <Widget>[
                      Expanded(child: Text('启用', style: Tga.body)),
                      Switch(
                        value: _enabled,
                        activeColor: Tga.primary,
                        onChanged: (bool v) => setState(() => _enabled = v),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    if (!isNew)
                      TgaButton(
                        label: '删除任务',
                        icon: Icons.delete_outline_rounded,
                        color: Tga.red,
                        filled: false,
                        onTap: _delete,
                      ),
                    const SizedBox(width: 10),
                    TgaButton(
                      label: _saving ? '保存中…' : '保存',
                      icon: Icons.check_rounded,
                      onTap: () {
                        if (!_saving) _save();
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          TgaCard(
            child: Text(
              '保存后由调度器每 30 秒检查一次，到点经对话链路真实执行并把结果写入对话记录；'
              '同一天不会重复执行。',
              style: Tga.sub,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final String name = _name.text.trim();
    if (name.isEmpty) {
      _toast(context, '请填写任务名');
      return;
    }
    setState(() => _saving = true);
    try {
      final BackendClient backend = context.read<BackendClient>();
      final String title =
          TaskScheduler.encodeTitle(name, _timeLabel, _desc.text);
      final _TaskRule? r = widget.rule;
      if (r == null) {
        await backend.sendControl(
            'proactive_task', <String, dynamic>{'action': 'add', 'title': title});
      } else {
        final bool titleChanged = title != r.title;
        if (titleChanged) {
          // 后端无改名接口：删除旧规则 + 按新标题重建（重建后默认为启用）。
          await backend.sendControl('proactive_task',
              <String, dynamic>{'action': 'delete', 'id': r.id});
          await backend.sendControl('proactive_task',
              <String, dynamic>{'action': 'add', 'title': title});
        }
        if (titleChanged || _enabled != r.enabled) {
          // 如实恢复开关：set_rule 按存储的 name（= 完整标题）匹配。
          await backend.sendControl('proactive_task', <String, dynamic>{
            'action': 'set_rule',
            'name': titleChanged ? title : r.title,
            'enabled': _enabled,
          });
        }
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast(context, '保存失败：$e');
    }
  }

  Future<void> _delete() async {
    final _TaskRule? r = widget.rule;
    if (r == null) return;
    final bool ok = await _confirm(context,
        title: '删除任务「${r.scheduled?.name ?? r.name}」',
        message: '删除后不会再自动执行，不可恢复。',
        okLabel: '删除');
    if (!ok) return;
    if (!mounted) return;
    try {
      final BackendClient backend = context.read<BackendClient>();
      await backend.sendControl(
          'proactive_task', <String, dynamic>{'action': 'delete', 'id': r.id});
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on Object catch (e) {
      if (!context.mounted) return;
      _toast(context, '删除失败：$e');
    }
  }
}

// ---------------------------------------------------------------------------
// 通用小工具：toast / 确认框 / 单行输入框
// ---------------------------------------------------------------------------
void _toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(12)));
}

Future<bool> _confirm(BuildContext context,
    {required String title,
    required String message,
    String okLabel = '确定'}) async {
  final bool? r = await showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      title: Text(title, style: Tga.h2),
      content: Text(message, style: Tga.body),
      actions: <Widget>[
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消')),
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(okLabel,
                style: TextStyle(color: Tga.red))),
      ],
    ),
  );
  return r == true;
}

Future<String?> _promptText(BuildContext context,
    {required String title, required String initial, String hint = ''}) async {
  final TextEditingController controller =
      TextEditingController(text: initial);
  final String? r = await showDialog<String>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      title: Text(title, style: Tga.h2),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: Tga.body,
        decoration: InputDecoration(
          hintText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
      actions: <Widget>[
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
        TextButton(
          onPressed: () =>
              Navigator.of(ctx).pop(controller.text.trim()),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  controller.dispose();
  return r;
}
