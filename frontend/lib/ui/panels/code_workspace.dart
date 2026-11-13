/// 旧版面板:当前 App 无入口引用,保留备查。

library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:tangram/agent/sandbox/sandboxed_shell.dart';
import 'package:tangram/flai/core/theme/tangram_palette.dart';
import 'package:tangram/flai/widgets/tangram_surfaces.dart';
import 'package:tangram/services/sandbox.dart';
import 'package:tangram/services/sandbox_runtime.dart';
import 'package:tangram/ui/panels/async_panel_mixin.dart';

class CodeColumn {
  CodeColumn(this.title, this.icon, this.lines);
  final String title;
  final IconData icon;
  final List<String> lines;
}

/// 内置沙箱共用控件：环境切换 + 后端策略摘要 + Python 运行时状态。
///
/// 路线 B：内置沙箱面板与训练蒸馏页共用同一套控件和离线诚实组件，
/// 不再各自硬写「未连接后端」静态文本。
class SandboxControls extends StatelessWidget {
  const SandboxControls({super.key});

  @override
  Widget build(BuildContext context) {
    final SandboxRuntime runtime = context.watch<SandboxRuntime>();
    final SandboxView sandboxView = context.watch<SandboxView>();
    final SandboxStatus policy = sandboxView.status;
    // 仅外部桥模式且确实缺 python3 时才提示；纯 Dart 内嵌后端不需要 Python，
    // 「Python 不可用」是设计使然，不是错误。
    final bool needsPythonHint = runtime.needsPythonHint;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Wrap(
          spacing: TangramSpacing.md,
          runSpacing: TangramSpacing.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            StatusPill(
              label: runtime.online ? '沙箱已连接' : '沙箱离线',
              color: runtime.online
                  ? TangramColors.success
                  : TangramColors.textMuted,
              dense: true,
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Text('环境',
                    style: TextStyle(
                        color: TangramColors.textMuted, fontSize: 12)),
                const SizedBox(width: TangramSpacing.sm),
                DropdownButton<String>(
                  value: SandboxRuntime.environments.contains(
                          runtime.environment)
                      ? runtime.environment
                      : SandboxRuntime.environments.first,
                  underline: const SizedBox.shrink(),
                  isDense: true,
                  style: const TextStyle(
                    color: TangramColors.textPrimary,
                    fontSize: 12,
                  ),
                  items: SandboxRuntime.environments
                      .map((String e) => DropdownMenuItem<String>(
                            value: e,
                            child: Text(e),
                          ))
                      .toList(),
                  onChanged: (String? v) {
                    if (v != null) runtime.setEnvironment(v);
                  },
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: TangramSpacing.sm),
        GlassCard(
          padding: const EdgeInsets.all(TangramSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                '隔离策略',
                style: TextStyle(
                  color: TangramColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: TangramSpacing.sm),
              if (sandboxView.isLoaded)
                Theme(
                  data: Theme.of(context).copyWith(
                    dividerColor: Colors.transparent,
                  ),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: EdgeInsets.zero,
                    title: Text(
                      policy.briefSummary,
                      style: const TextStyle(
                        color: TangramColors.textSecondary,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                    children: <Widget>[
                      Text(
                        policy.summary,
                        style: const TextStyle(
                          color: TangramColors.textMuted,
                          fontSize: 11,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                )
              else
                const Text(
                  '策略未加载：沙箱还没启动。',
                  style: TextStyle(
                    color: TangramColors.textSecondary,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              if (runtime.embeddedReady) ...<Widget>[
                const SizedBox(height: TangramSpacing.sm),
                const Row(
                  children: <Widget>[
                    Icon(Icons.check_circle_outline,
                        size: 14, color: TangramColors.success),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '沙箱已就绪',
                        style: TextStyle(
                          color: TangramColors.textSecondary,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ] else if (needsPythonHint) ...<Widget>[
                const SizedBox(height: TangramSpacing.sm),
                const Text(
                  kNoPythonHint,
                  style: TextStyle(
                    color: TangramColors.danger,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class CodeWorkspacePanel extends StatefulWidget {
  const CodeWorkspacePanel({super.key});

  @override
  State<CodeWorkspacePanel> createState() => _CodeWorkspacePanelState();
}

class _CodeWorkspacePanelState extends State<CodeWorkspacePanel>
    with AsyncPanelMixin {
  CodeColumn _code = CodeColumn('能力契约', Icons.schema, const <String>[]);
  CodeColumn _diff = CodeColumn('执行日志', Icons.receipt_long, const <String>[]);
  CodeColumn _test = CodeColumn('测试', Icons.check_circle, const <String>[]);
  final TextEditingController _expr = TextEditingController(text: '1 + 2 * 3');
  final FocusNode _exprFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<String> _strList(dynamic v) {
    if (v is List) return v.map((e) => e.toString()).toList();
    if (v is String) return v.split('\n');
    return const <String>[];
  }

  /// 从内置 Dart 沙箱的能力契约加载真实可执行的 cube 清单。
  Future<void> _load() => runGuarded(() async {
        await SandboxedShell.instance.ensureLoaded();
        final contract = SandboxedShell.instance.contract;
        if (contract == null) {
          _code = CodeColumn('能力契约', Icons.schema,
              const <String>['契约未加载，暂不能执行。']);
          return;
        }
        final lines = <String>[];
        for (final entry in contract.cubes.entries) {
          final spec = entry.value;
          final missing = <String>[
            for (final cap in spec.requires)
              if (!SandboxedExecutionEnv.provisioned.contains(cap)) cap,
          ];
          final status = missing.isEmpty
              ? '可执行'
              : '拒绝（缺能力: ${missing.join(", ")}）';
          lines.add('${spec.name}  [${spec.backend}]  $status');
          lines.add('    ${spec.description}');
        }
        lines.add('allowDegrade = ${contract.allowDegrade}');
        _code = CodeColumn('能力契约', Icons.schema, lines);
      });

  Future<void> _runTest() => runGuarded(() async {
        final result = await SandboxedShell.instance.exec('run_test');
        _test = CodeColumn(
          '测试',
          Icons.check_circle,
          _strList(result.stdout),
        );
        _diff = CodeColumn('执行日志', Icons.receipt_long,
            <String>['[$_now] run_test → ${result.ok ? "ok" : "fail"}']);
      });

  Future<void> _runExpr() => runGuarded(() async {
        final code = _expr.text.trim();
        if (code.isEmpty) return;
        try {
          final result =
              await SandboxedShell.instance.exec('eval_expression', {
            'code': code,
          });
          _diff = CodeColumn('执行日志', Icons.receipt_long, <String>[
            '[$_now] eval($code) → ${result.stdout}',
          ]);
        } on RefusalError catch (e) {
          _diff = CodeColumn('执行日志', Icons.receipt_long, <String>[
            '[$_now] REFUSE[${e.code}] ${e.message}',
          ]);
        }
      });

  String get _now {
    final t = DateTime.now();
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> columns = <Widget>[
      _ColumnCard(column: _code),
      _ColumnCard(column: _diff),
      _ColumnCard(column: _test),
    ];
    return PanelPage(
      children: <Widget>[
        const SectionTitle(
          title: '内置沙箱',
          subtitle: '隔离运行表达式',
          icon: Icons.terminal_outlined,
          accent: TangramColors.gold,
        ),
        const SandboxControls(),
        // 离线/错误/加载统一交给 BackendStatusBanner（含「启动内置沙箱」按钮）。
        buildStatusBlock(),
        const SizedBox(height: TangramSpacing.md),
        TextField(
          controller: _expr,
          focusNode: _exprFocus,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            color: TangramColors.textPrimary,
          ),
          decoration: InputDecoration(
            hintText: '输入受限表达式，如 1 + 2 * 3 或 [1,2,3]',
            hintStyle: const TextStyle(color: TangramColors.textMuted),
            filled: true,
            fillColor: TangramColors.surfaceRaised,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(TangramRadii.sm),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: TangramSpacing.md,
              vertical: TangramSpacing.sm,
            ),
          ),
          onSubmitted: (_) => _runExpr(),
        ),
        const SizedBox(height: TangramSpacing.sm),
        Wrap(
          spacing: TangramSpacing.md,
          runSpacing: TangramSpacing.sm,
          children: <Widget>[
            FilledButton.icon(
              onPressed: loading ? null : _runExpr,
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('执行表达式'),
            ),
            OutlinedButton.icon(
              onPressed: loading ? null : _runTest,
              icon: const Icon(Icons.check_circle, size: 18),
              label: const Text('运行测试'),
            ),
            OutlinedButton.icon(
              onPressed: loading ? null : _load,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('刷新契约'),
            ),
          ],
        ),
        const SizedBox(height: TangramSpacing.lg),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool threeCol = constraints.maxWidth >= 900;
            if (!threeCol) {
              return Column(
                children: columns
                    .expand(
                      (Widget w) => <Widget>[
                        w,
                        const SizedBox(height: TangramSpacing.md),
                      ],
                    )
                    .toList(),
              );
            }
            final List<Widget> row = <Widget>[];
            for (int i = 0; i < columns.length; i++) {
              if (i > 0) row.add(const SizedBox(width: TangramSpacing.md));
              row.add(Expanded(child: columns[i]));
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: row,
            );
          },
        ),
      ],
    );
  }
}

class _ColumnCard extends StatelessWidget {
  const _ColumnCard({required this.column});
  final CodeColumn column;

  @override
  Widget build(BuildContext context) {
    final Color accent = column.icon == Icons.check_circle
        ? TangramColors.success
        : column.icon == Icons.receipt_long
            ? TangramColors.gold
            : TangramColors.jade;
    return GlassCard(
      padding: const EdgeInsets.all(TangramSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(TangramRadii.sm),
                  border: Border.all(color: accent.withOpacity(0.24)),
                ),
                child: Icon(column.icon, size: 16, color: accent),
              ),
              const SizedBox(width: TangramSpacing.sm),
              Text(column.title, style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              if (column.lines.isNotEmpty)
                StatusPill(
                  label: '${column.lines.length} 行',
                  color: accent,
                  dense: true,
                ),
            ],
          ),
          const SizedBox(height: TangramSpacing.md),
          if (column.lines.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: TangramSpacing.md),
              child: Text(
                kOfflineHint,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: TangramColors.textMuted,
                ),
              ),
            )
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(TangramSpacing.md),
              decoration: BoxDecoration(
                color: TangramColors.surfaceRaised,
                borderRadius: BorderRadius.circular(TangramRadii.sm),
                border: Border.all(color: TangramColors.borderL2),
              ),
              child: Text(
                column.lines.join('\n'),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.5,
                  color: TangramColors.textPrimary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
