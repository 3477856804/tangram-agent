import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';
import '../../harness/account_ops.dart';
import '../../harness/embedded_backend.dart';
import '../../harness/store.dart';

/// AI 账号运营（人工确认）：账号 / 草稿 / 审批 / 发布状态 / 审计。
///
/// 页面只调用 [AccountOps]：账号只显示凭据引用，草稿必须人工提交、审批
/// 通过后才允许发布；发布结果（含失败错误）原样展示，不伪造成功。
class TgaAccountOpsPage extends StatefulWidget {
  const TgaAccountOpsPage({super.key, this.ops, this.sender});

  /// 构造时可注入服务或发布回调；预览时默认回调如实返回未接入。
  final AccountOps? ops;
  final AccountSender? sender;

  @override
  State<TgaAccountOpsPage> createState() => _TgaAccountOpsPageState();
}

class _TgaAccountOpsPageState extends State<TgaAccountOpsPage> {
  AccountOps? _ops;
  List<Map<String, dynamic>> _accounts = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _drafts = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _interactions = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _orders = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _audit = <Map<String, dynamic>>[];
  String _lastPublishDue = '';
  bool _loading = true;
  bool _busy = false;
  String _error = '';

  AccountSender _senderFromBackend() {
    final EmbeddedBackend? embedded =
        context.read<BackendClient>().embeddedBackend;
    if (embedded == null) return _previewSend;
    return (String channel, Map<String, dynamic> payload) =>
        embedded.accountOpsSend(channel, payload);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  static Future<Map<String, dynamic>> _previewSend(
      String channel, Map<String, dynamic> payload) async {
    return <String, dynamic>{
      'ok': false,
      'error': '未接入发布通道（请在宿主注入真实 send 回调）',
    };
  }

  Future<void> _init() async {
    try {
      final AccountOps ops = widget.ops ??
          AccountOps(
            await HarnessStore.instance(),
            send: widget.sender ?? _senderFromBackend(),
          );
      final List<Map<String, dynamic>> accounts = await ops.listAccounts();
      final List<Map<String, dynamic>> drafts = await ops.listDrafts();
      final List<Map<String, dynamic>> interactions = await ops.listInteractions();
      final List<Map<String, dynamic>> orders = await ops.listOrders();
      final List<Map<String, dynamic>> audit = await ops.audit(limit: 30);
      if (!mounted) return;
      setState(() {
        _ops = ops;
        _accounts = accounts;
        _drafts = drafts;
        _interactions = interactions;
        _orders = orders;
        _audit = audit;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '账号运营读取失败：$e';
      });
    }
  }

  Future<void> _refresh() async {
    final AccountOps? ops = _ops;
    if (ops == null) return;
    final List<Map<String, dynamic>> accounts = await ops.listAccounts();
    final List<Map<String, dynamic>> drafts = await ops.listDrafts();
    final List<Map<String, dynamic>> interactions = await ops.listInteractions();
    final List<Map<String, dynamic>> orders = await ops.listOrders();
    final List<Map<String, dynamic>> audit = await ops.audit(limit: 30);
    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      _drafts = drafts;
      _interactions = interactions;
      _orders = orders;
      _audit = audit;
    });
  }

  Future<void> _run(Future<Map<String, dynamic>> Function() action,
      {bool refresh = true}) async {
    if (_busy) return;
    setState(() => _busy = true);
    Map<String, dynamic> r;
    try {
      r = await action();
    } on Object catch (e) {
      r = <String, dynamic>{'ok': false, 'error': '操作异常：$e'};
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(r['ok'] == true
        ? '操作完成'
        : (r['error'] ?? '操作失败').toString());
    if (refresh) {
      try {
        await _refresh();
      } on Object catch (e) {
        _toast('刷新失败：$e');
      }
    }
  }

  Future<void> _addAccount() async {
    final AccountOps? ops = _ops;
    if (ops == null) return;
    final TextEditingController channel = TextEditingController();
    final TextEditingController name = TextEditingController();
    final TextEditingController ref = TextEditingController();
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('添加账号', style: Tga.h2),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: channel,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(
                  hintText: '渠道，如 wechat / feishu / x',
                ),
              ),
              TextField(
                controller: name,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(hintText: '账号名称'),
              ),
              TextField(
                controller: ref,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(
                  hintText: '凭据引用，如 env:WECHAT_TOKEN（绝不填明文密钥）',
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: Tga.textSub)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final String ch = channel.text;
    final String nm = name.text;
    final String rf = ref.text;
    channel.dispose();
    name.dispose();
    ref.dispose();
    if (go != true || !mounted) return;
    await _run(() => ops.addAccount(
          channel: ch,
          name: nm,
          credentialRef: rf,
        ));
  }

  Future<void> _toggle(Map<String, dynamic> account) async {
    final AccountOps? ops = _ops;
    if (ops == null) return;
    await _run(() => ops.toggleAccount(
          (account['id'] ?? '').toString(),
          account['enabled'] == false,
        ));
  }

  Future<void> _removeAccount(Map<String, dynamic> account) async {
    final AccountOps? ops = _ops;
    if (ops == null) return;
    final bool ok = await showDialog<bool>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            backgroundColor: Tga.card,
            title: Text('移除账号「${account['name']}」？', style: Tga.h2),
            content: Text('仅删除账号配置，历史草稿与审计日志保留。', style: Tga.body),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text('取消', style: TextStyle(color: Tga.textSub)),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text('移除', style: TextStyle(color: Tga.red)),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    await _run(() => ops.removeAccount((account['id'] ?? '').toString()));
  }

  Future<void> _createDraft() async {
    final AccountOps? ops = _ops;
    if (ops == null) return;
    final List<Map<String, dynamic>> enabled = _accounts
        .where((Map<String, dynamic> a) => a['enabled'] != false)
        .toList();
    if (enabled.isEmpty) {
      _toast('请先添加并启用一个账号');
      return;
    }
    String accountId = (enabled.first['id'] ?? '').toString();
    final TextEditingController content = TextEditingController();
    final TextEditingController media = TextEditingController();
    final TextEditingController target = TextEditingController();
    final TextEditingController schedule = TextEditingController();
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) => AlertDialog(
          backgroundColor: Tga.card,
          title: Text('新建草稿', style: Tga.h2),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                DropdownButtonFormField<String>(
                  value: accountId,
                  dropdownColor: Tga.card,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(labelText: '账号'),
                  items: <DropdownMenuItem<String>>[
                    for (final Map<String, dynamic> a in enabled)
                      DropdownMenuItem<String>(
                        value: (a['id'] ?? '').toString(),
                        child: Text('${a['name']} · ${a['channel']}'),
                      ),
                  ],
                  onChanged: (String? v) =>
                      setLocal(() => accountId = v ?? accountId),
                ),
                TextField(
                  controller: content,
                  minLines: 3,
                  maxLines: 8,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(hintText: '正文内容'),
                ),
                TextField(
                  controller: media,
                  minLines: 2,
                  maxLines: 5,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(
                      hintText: '素材路径，每行一个（可选）'),
                ),
                TextField(
                  controller: target,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(
                      hintText: '发布目标（可选，默认渠道）'),
                ),
                TextField(
                  controller: schedule,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(
                      hintText: '排期时间 ISO8601（可选，如 2026-11-18T09:00:00）'),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: Tga.textSub)),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('保存草稿'),
            ),
          ],
        ),
      ),
    );
    final List<String> mediaPaths = media.text
        .split('\n')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    final Map<String, dynamic> r = go == true
        ? await ops.createDraft(
            accountId: accountId,
            content: content.text,
            mediaPaths: mediaPaths,
            target: target.text,
            scheduledAt: schedule.text,
          )
        : <String, dynamic>{'ok': false, 'error': '已取消'};
    content.dispose();
    media.dispose();
    target.dispose();
    schedule.dispose();
    if (!mounted || go != true) return;
    _toast(r['ok'] == true
        ? '草稿已创建（draft），需提交并人工审批'
        : (r['error'] ?? '创建失败').toString());
    if (r['ok'] == true) await _refresh();
  }

  Future<void> _reject(Map<String, dynamic> draft) async {
    final AccountOps? ops = _ops;
    if (ops == null) return;
    final TextEditingController reason = TextEditingController();
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('驳回草稿', style: Tga.h2),
        content: TextField(
          controller: reason,
          minLines: 2,
          maxLines: 5,
          style: TextStyle(color: Tga.text),
          decoration: const InputDecoration(hintText: '驳回原因（可选）'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: Tga.textSub)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('驳回'),
          ),
        ],
      ),
    );
    final String text = reason.text;
    reason.dispose();
    if (go != true || !mounted) return;
    await _run(() => ops.rejectDraft((draft['id'] ?? '').toString(), text));
  }

  Future<void> _publishDue() async {
    final AccountOps? ops = _ops;
    if (ops == null) return;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final Map<String, dynamic> r = await ops.publishDue();
      if (!mounted) return;
      final int published =
          (r['published'] is num) ? (r['published'] as num).toInt() : 0;
      final int failed =
          (r['failed'] is num) ? (r['failed'] as num).toInt() : 0;
      final int skipped =
          (r['skipped'] is num) ? (r['skipped'] as num).toInt() : 0;
      setState(() {
        _busy = false;
        _lastPublishDue = r['ok'] == true
            ? '到期 ${r['due']} 条：成功 $published，失败 $failed，跳过 $skipped'
            : '定时发布失败：${r['error'] ?? 'ok=false'}';
      });
      _toast(_lastPublishDue);
      await _refresh();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _lastPublishDue = '定时发布异常：$e';
      });
      _toast(_lastPublishDue);
    }
  }

  Future<String?> _promptText(String title, String hint,
      {String initial = ''}) async {
    final TextEditingController ctrl =
        TextEditingController(text: initial);
    final String? value = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text(title, style: Tga.h2),
        content: TextField(
          controller: ctrl,
          style: TextStyle(color: Tga.text),
          decoration: InputDecoration(hintText: hint),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消', style: TextStyle(color: Tga.textSub)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return value;
  }

  Future<void> _addInteraction() async {
    final AccountOps? ops = _ops;
    if (ops == null) return;
    final List<Map<String, dynamic>> accounts = _accounts;
    String accountId = accounts.isEmpty
        ? ''
        : (accounts.first['id'] ?? '').toString();
    final TextEditingController channel = TextEditingController();
    final TextEditingController target = TextEditingController();
    final TextEditingController summary = TextEditingController();
    String direction = 'out';
    String status = 'logged';
    final TextEditingController statusCtrl = TextEditingController(text: status);
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) => AlertDialog(
          backgroundColor: Tga.card,
          title: Text('新增互动记录', style: Tga.h2),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                DropdownButtonFormField<String>(
                  value: accountId.isEmpty ? '' : accountId,
                  dropdownColor: Tga.card,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(labelText: '关联账号（可选）'),
                  items: <DropdownMenuItem<String>>[
                    const DropdownMenuItem<String>(
                        value: '', child: Text('不关联账号')),
                    for (final Map<String, dynamic> a in accounts)
                      DropdownMenuItem<String>(
                        value: (a['id'] ?? '').toString(),
                        child: Text('${a['name']} · ${a['channel']}'),
                      ),
                  ],
                  onChanged: (String? v) => setLocal(() => accountId = v ?? ''),
                ),
                TextField(
                  controller: channel,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(
                      hintText: '渠道（关联账号时可留空）'),
                ),
                TextField(
                  controller: target,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(hintText: '目标/会话/帖子'),
                ),
                DropdownButtonFormField<String>(
                  value: direction,
                  dropdownColor: Tga.card,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(labelText: '方向'),
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem<String>(value: 'out', child: Text('out 我方发出')),
                    DropdownMenuItem<String>(value: 'in', child: Text('in 对方互动')),
                  ],
                  onChanged: (String? v) =>
                      setLocal(() => direction = v ?? 'out'),
                ),
                TextField(
                  controller: summary,
                  minLines: 2,
                  maxLines: 5,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(
                      hintText: '互动摘要（只记业务元数据，不填密钥/隐私正文）'),
                ),
                TextField(
                  controller: statusCtrl,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(hintText: '状态，默认 logged'),
                  onChanged: (String v) => status = v,
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: Tga.textSub)),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    final String ch = channel.text;
    final String tg = target.text;
    final String sm = summary.text;
    channel.dispose();
    target.dispose();
    summary.dispose();
    statusCtrl.dispose();
    if (go != true || !mounted) return;
    await _run(() => ops.addInteraction(
          channel: ch,
          accountId: accountId,
          target: tg,
          direction: direction,
          summary: sm,
          status: status,
        ));
  }

  Future<void> _addOrder() async {
    final AccountOps? ops = _ops;
    if (ops == null) return;
    if (_accounts.isEmpty) {
      _toast('请先添加一个账号');
      return;
    }
    String accountId = (_accounts.first['id'] ?? '').toString();
    final TextEditingController platformOrderId = TextEditingController();
    final TextEditingController title = TextEditingController();
    final TextEditingController amount = TextEditingController();
    final TextEditingController status = TextEditingController(text: 'pending');
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) => AlertDialog(
          backgroundColor: Tga.card,
          title: Text('新增/更新订单', style: Tga.h2),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                DropdownButtonFormField<String>(
                  value: accountId,
                  dropdownColor: Tga.card,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(labelText: '账号'),
                  items: <DropdownMenuItem<String>>[
                    for (final Map<String, dynamic> a in _accounts)
                      DropdownMenuItem<String>(
                        value: (a['id'] ?? '').toString(),
                        child: Text('${a['name']} · ${a['channel']}'),
                      ),
                  ],
                  onChanged: (String? v) =>
                      setLocal(() => accountId = v ?? accountId),
                ),
                TextField(
                  controller: platformOrderId,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(
                      hintText: '平台订单号（同账号幂等更新）'),
                ),
                TextField(
                  controller: title,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(hintText: '订单标题'),
                ),
                TextField(
                  controller: amount,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(hintText: '金额，如 99.00'),
                ),
                TextField(
                  controller: status,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(
                      hintText: '状态，如 pending/paid/shipped'),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: Tga.textSub)),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    final String orderId = platformOrderId.text;
    final String orderTitle = title.text;
    final String amountText = amount.text;
    final String orderStatus = status.text;
    platformOrderId.dispose();
    title.dispose();
    amount.dispose();
    status.dispose();
    if (go != true || !mounted) return;
    final double? parsedAmount = double.tryParse(amountText.trim());
    if (parsedAmount == null) {
      _toast('金额必须是数字');
      return;
    }
    await _run(() => ops.upsertOrder(
          accountId: accountId,
          platformOrderId: orderId,
          title: orderTitle,
          amount: parsedAmount,
          status: orderStatus,
        ));
  }

  Future<void> _updateInteractionStatus(Map<String, dynamic> record) async {
    final AccountOps? ops = _ops;
    if (ops == null) return;
    final String? status = await _promptText(
      '更新互动状态',
      '如 logged/replied/closed',
      initial: (record['status'] ?? '').toString(),
    );
    if (status == null || status.trim().isEmpty || !mounted) return;
    final String next = status.trim();
    await _run(() =>
        ops.updateInteractionStatus((record['id'] ?? '').toString(), next));
  }

  Future<void> _updateOrderStatus(Map<String, dynamic> order) async {
    final AccountOps? ops = _ops;
    if (ops == null) return;
    final String? status = await _promptText(
      '更新订单状态',
      '如 pending/paid/shipped/refunded',
      initial: (order['status'] ?? '').toString(),
    );
    if (status == null || status.trim().isEmpty || !mounted) return;
    final String next = status.trim();
    await _run(() =>
        ops.updateOrderStatus((order['id'] ?? '').toString(), next));
  }

  Map<String, dynamic>? _accountOf(String id) {
    for (final Map<String, dynamic> a in _accounts) {
      if (a['id'] == id) return a;
    }
    return null;
  }

  String _accountName(String id) {
    if (id.trim().isEmpty) return '未关联账号';
    final Map<String, dynamic>? account = _accountOf(id);
    final String name = (account?['name'] ?? '').toString().trim();
    return name.isEmpty ? '账号' : name;
  }

  /// 所有带排期时间的草稿（含尚未审批），按时间升序展示。
  List<Map<String, dynamic>> get _scheduledDrafts {
    final List<Map<String, dynamic>> list = _drafts
        .where((Map<String, dynamic> d) =>
            (d['scheduled_at'] ?? '').toString().trim().isNotEmpty)
        .toList()
      ..sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
          (a['scheduled_at'] ?? '')
              .toString()
              .compareTo((b['scheduled_at'] ?? '').toString()));
    return list;
  }

  bool _isDraftDue(Map<String, dynamic> draft) {
    if ((draft['status'] ?? '') != 'approved') return false;
    final DateTime? at =
        DateTime.tryParse((draft['scheduled_at'] ?? '').toString());
    if (at == null || at.isAfter(DateTime.now())) return false;
    final Map<String, dynamic>? account =
        _accountOf((draft['account_id'] ?? '').toString());
    return account != null && account['enabled'] != false;
  }

  Color _orderStatusColor(String status) => switch (status) {
        'paid' || 'shipped' || 'completed' || 'done' => Tga.green,
        'pending' => Tga.orange,
        'refunded' || 'cancelled' || 'failed' => Tga.red,
        _ => Tga.textSub,
      };

  Color _statusColor(String status) => switch (status) {
        'approved' => Tga.primary,
        'pending' => Tga.orange,
        'published' => Tga.green,
        'rejected' => Tga.red,
        'failed' => Tga.red,
        _ => Tga.textSub,
      };

  String _statusLabel(String status) => switch (status) {
        'draft' => '草稿',
        'pending' => '待审批',
        'approved' => '已批准',
        'rejected' => '已驳回',
        'published' => '已发布',
        'failed' => '发布失败',
        _ => status,
      };

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
  }

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: '账号运营',
      actions: <Widget>[
        IconButton(
          tooltip: '新建草稿',
          onPressed: _loading || _busy ? null : _createDraft,
          icon: Icon(Icons.edit_note_rounded, color: Tga.primary),
        ),
        IconButton(
          tooltip: '添加账号',
          onPressed: _loading || _busy ? null : _addAccount,
          icon: Icon(Icons.add_rounded, color: Tga.primary),
        ),
        IconButton(
          tooltip: '刷新',
          onPressed: _loading || _busy ? null : _refresh,
          icon: Icon(Icons.refresh_rounded, color: Tga.primary),
        ),
      ],
      child: _loading
          ? Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Tga.primary),
              ),
            )
          : ListView(
              padding:
                  const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
              children: <Widget>[
                if (_error.isNotEmpty)
                  TgaCard(
                    child:
                        Text(_error, style: Tga.sub.copyWith(color: Tga.red)),
                  ),
                TgaGroupTitle('账号（${_accounts.length}）'),
                if (_accounts.isEmpty)
                  TgaCard(
                    child: TgaEmpty('还没有账号\n添加时只填写凭据引用，不保存明文密钥',
                        icon: Icons.person_outline_rounded),
                  )
                else
                  for (final Map<String, dynamic> a in _accounts)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: TgaCard(
                        child: Row(
                          children: <Widget>[
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: a['enabled'] == false
                                    ? Tga.iconRedBg
                                    : Tga.iconBlueBg,
                                borderRadius: BorderRadius.circular(11),
                              ),
                              child: Icon(Icons.alternate_email_rounded,
                                  size: 18,
                                  color: a['enabled'] == false
                                      ? Tga.iconRed
                                      : Tga.iconBlue),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Row(
                                    children: <Widget>[
                                      Flexible(
                                        child: Text((a['name'] ?? '').toString(),
                                            style: Tga.h2,
                                            overflow: TextOverflow.ellipsis),
                                      ),
                                      const SizedBox(width: 6),
                                      TgaTag((a['channel'] ?? '').toString()),
                                      if (a['enabled'] == false) ...<Widget>[
                                        const SizedBox(width: 6),
                                        TgaTag('已停用', color: Tga.red),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '凭据引用：${a['credential_ref'] ?? ''}',
                                    style: Tga.caption,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            Switch(
                              value: a['enabled'] != false,
                              onChanged: _busy ? null : (_) => _toggle(a),
                            ),
                            IconButton(
                              tooltip: '移除',
                              onPressed:
                                  _busy ? null : () => _removeAccount(a),
                              icon: Icon(Icons.delete_outline_rounded,
                                  size: 18, color: Tga.red),
                            ),
                          ],
                        ),
                      ),
                    ),
                TgaGroupTitle('草稿（${_drafts.length}）'),
                if (_drafts.isEmpty)
                  TgaCard(
                    child: TgaEmpty('还没有草稿\n新建后需提交并由人工审批',
                        icon: Icons.article_outlined),
                  )
                else
                  for (final Map<String, dynamic> d in _drafts)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: TgaCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    _accountName(
                                        (d['account_id'] ?? '').toString()),
                                    style: Tga.h2,
                                  ),
                                ),
                                TgaTag(
                                  _statusLabel((d['status'] ?? '').toString()),
                                  color: _statusColor(
                                      (d['status'] ?? '').toString()),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              (d['content'] ?? '').toString().isEmpty
                                  ? '（仅素材）'
                                  : (d['content'] ?? '').toString(),
                              style: Tga.body,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (d['media_paths'] is List &&
                                (d['media_paths'] as List).isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  '素材 ${(d['media_paths'] as List).length} 个：'
                                  '${(d['media_paths'] as List).join(' / ')}',
                                  style: Tga.caption,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            const SizedBox(height: 4),
                            Text(
                              '目标 ${d['target'] ?? ''}'
                              '${(d['scheduled_at'] ?? '').toString().isEmpty ? '' : ' · 排期 ${d['scheduled_at']}'}'
                              ' · 审计 ${(d['audit'] is List) ? (d['audit'] as List).length : 0} 条',
                              style: Tga.caption,
                            ),
                            if ((d['error'] ?? '').toString().isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  '错误：${d['error']}',
                                  style:
                                      Tga.caption.copyWith(color: Tga.red),
                                ),
                              ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: <Widget>[
                                if ((d['status'] ?? '') == 'draft' ||
                                    (d['status'] ?? '') == 'rejected')
                                  TgaButton(
                                    label: '提交审批',
                                    icon: Icons.send_outlined,
                                    onTap: _busy
                                        ? () {}
                                        : () => _run(() => _ops!.submitDraft(
                                            (d['id'] ?? '').toString())),
                                  ),
                                if ((d['status'] ?? '') == 'pending') ...<Widget>[
                                  TgaButton(
                                    label: '驳回',
                                    filled: false,
                                    color: Tga.red,
                                    icon: Icons.close_rounded,
                                    onTap: _busy ? () {} : () => _reject(d),
                                  ),
                                  const SizedBox(width: 8),
                                  TgaButton(
                                    label: '人工通过',
                                    icon: Icons.verified_outlined,
                                    onTap: _busy
                                        ? () {}
                                        : () => _run(() => _ops!.approveDraft(
                                            (d['id'] ?? '').toString())),
                                  ),
                                ],
                                if ((d['status'] ?? '') == 'approved')
                                  TgaButton(
                                    label: '发布',
                                    color: Tga.green,
                                    icon: Icons.publish_rounded,
                                    onTap: _busy
                                        ? () {}
                                        : () => _run(() => _ops!.publishDraft(
                                            (d['id'] ?? '').toString())),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                TgaGroupTitle(
                  '定时发布（${_scheduledDrafts.length}）',
                  trailing: TgaButton(
                    label: '发布到期草稿',
                    icon: Icons.schedule_rounded,
                    onTap: _busy ? () {} : () => _publishDue(),
                  ),
                ),
                if (_lastPublishDue.isNotEmpty)
                  TgaCard(
                    child: Text(
                      '$_lastPublishDue\n'
                      '仅发布 approved + 已到点 + 账号启用的草稿；不会自动审批。',
                      style: Tga.sub,
                    ),
                  ),
                if (_scheduledDrafts.isEmpty)
                  TgaCard(
                    child: TgaEmpty('暂无定时草稿\n新建草稿时填写排期时间即可',
                        icon: Icons.schedule_outlined),
                  )
                else
                  for (final Map<String, dynamic> d in _scheduledDrafts)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: TgaCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    _accountName(
                                        (d['account_id'] ?? '').toString()),
                                    style: Tga.h2,
                                  ),
                                ),
                                TgaTag(
                                  _statusLabel((d['status'] ?? '').toString()),
                                  color: _statusColor(
                                      (d['status'] ?? '').toString()),
                                ),
                                if (_isDraftDue(d)) ...<Widget>[
                                  const SizedBox(width: 6),
                                  TgaTag('已到点', color: Tga.green),
                                ],
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '排期 ${d['scheduled_at']} · 目标 ${d['target'] ?? ''}',
                              style: Tga.caption,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              (d['content'] ?? '').toString().isEmpty
                                  ? '（仅素材）'
                                  : (d['content'] ?? '').toString(),
                              style: Tga.sub,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if ((d['status'] ?? '') == 'approved')
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: TgaButton(
                                  label: '立即发布此草稿',
                                  color: Tga.green,
                                  icon: Icons.publish_rounded,
                                  onTap: _busy
                                      ? () {}
                                      : () => _run(() => _ops!.publishDraft(
                                          (d['id'] ?? '').toString())),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                TgaGroupTitle(
                  '互动记录（${_interactions.length}）',
                  trailing: TgaButton(
                    label: '新增互动',
                    icon: Icons.add_rounded,
                    onTap: _busy ? () {} : () => _addInteraction(),
                  ),
                ),
                if (_interactions.isEmpty)
                  TgaCard(
                    child: TgaEmpty(
                        '暂无互动记录\n只记录渠道/目标/方向/摘要等业务元数据',
                        icon: Icons.forum_outlined),
                  )
                else
                  for (final Map<String, dynamic> i in _interactions)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TgaCard(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                TgaTag(
                                  (i['direction'] ?? '').toString() == 'in'
                                      ? '对方 in'
                                      : '我方 out',
                                  color: (i['direction'] ?? '') == 'in'
                                      ? Tga.purple
                                      : Tga.primary,
                                ),
                                const SizedBox(width: 6),
                                TgaTag(
                                    (i['channel'] ?? '').toString(),
                                    color: Tga.textSub),
                                const Spacer(),
                                TgaTag(
                                  (i['status'] ?? '').toString(),
                                  color: Tga.textSub,
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${_accountName((i['account_id'] ?? '').toString())}'
                              ' · 目标 ${(i['target'] ?? '').toString().isEmpty ? '—' : i['target']}',
                              style: Tga.caption,
                            ),
                            const SizedBox(height: 2),
                            Text((i['summary'] ?? '').toString(),
                                style: Tga.body,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 4),
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    '${i['at'] ?? ''}'.replaceFirst('T', ' '),
                                    style: Tga.caption,
                                  ),
                                ),
                                TgaButton(
                                  label: '更新状态',
                                  filled: false,
                                  onTap: _busy
                                      ? () {}
                                      : () => _updateInteractionStatus(i),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                TgaGroupTitle(
                  '订单记录（${_orders.length}）',
                  trailing: TgaButton(
                    label: '新增/更新订单',
                    icon: Icons.receipt_long_outlined,
                    onTap: _busy ? () {} : () => _addOrder(),
                  ),
                ),
                if (_orders.isEmpty)
                  TgaCard(
                    child: TgaEmpty('暂无订单记录\n按平台订单号幂等写入，重复保存只更新',
                        icon: Icons.receipt_long_outlined),
                  )
                else
                  for (final Map<String, dynamic> o in _orders)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TgaCard(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    (o['title'] ?? '').toString(),
                                    style: Tga.h2,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                TgaTag(
                                  (o['status'] ?? '').toString(),
                                  color: _orderStatusColor(
                                      (o['status'] ?? '').toString()),
                                ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${_accountName((o['account_id'] ?? '').toString())}'
                              ' · 平台单号 ${o['platform_order_id'] ?? ''}'
                              ' · 金额 ${o['amount'] ?? ''}',
                              style: Tga.caption,
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    '更新于 ${(o['updated_at'] ?? '').toString().replaceFirst('T', ' ')}',
                                    style: Tga.caption,
                                  ),
                                ),
                                TgaButton(
                                  label: '更新状态',
                                  filled: false,
                                  onTap: _busy
                                      ? () {}
                                      : () => _updateOrderStatus(o),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                const TgaGroupTitle('平台规则（只读）'),
                TgaCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      for (final String rule in AccountOps.platformRules)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Icon(Icons.info_outline_rounded,
                                  size: 14, color: Tga.primary),
                              const SizedBox(width: 6),
                              Expanded(child: Text(rule, style: Tga.sub)),
                            ],
                          ),
                        ),
                      const SizedBox(height: 4),
                      Text(
                        '发布必须由人工 approve；定时发布只处理 approved 且已到点的草稿，'
                        '不会自动审批；本页没有刷量 / 造假开关。',
                        style: Tga.caption,
                      ),
                    ],
                  ),
                ),
                TgaGroupTitle('审计日志（append-only，最近 ${_audit.length} 条）'),
                if (_audit.isEmpty)
                  TgaCard(child: TgaEmpty('暂无审计记录', icon: Icons.history_rounded))
                else
                  for (final Map<String, dynamic> e
                      in _audit.reversed.take(20))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: TgaCard(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Icon(Icons.history_rounded,
                                size: 15, color: Tga.textDim),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    '${e['action']} · ${e['object']}',
                                    style: Tga.body,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${(e['ts'] ?? '').toString().replaceFirst('T', ' ').split('.').first}'
                                    ' · ${e['actor']}'
                                    '${(e['detail'] ?? '').toString().isEmpty ? '' : ' · ${e['detail']}'}',
                                    style: Tga.caption,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
    );
  }
}
