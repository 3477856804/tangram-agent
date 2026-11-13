/// 旧版面板:当前 App 无入口引用,保留备查。

library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:tangram/flai/core/theme/tangram_palette.dart';
import 'package:tangram/flai/widgets/tangram_surfaces.dart';
import 'package:tangram/services/device_file_platform.dart';
import 'package:tangram/services/device_files.dart';
import 'package:tangram/services/persona_store.dart';
import 'package:tangram/services/sandbox.dart';

/// 工作区域：由用户手动选定隔离文件夹，所有读写 / 删除都限制在该目录内。
/// 隔离根与内置沙箱 sandbox.py 的可写根统一；保留存储权限与
/// 「一键全文件访问」应急开关。
class DeviceFilesPanel extends StatefulWidget {
  const DeviceFilesPanel({super.key, this.service});

  final DeviceFileService? service;

  @override
  State<DeviceFilesPanel> createState() => _DeviceFilesPanelState();
}

class _DeviceFilesPanelState extends State<DeviceFilesPanel> {
  late DeviceFileService _svc;
  DeviceFileAccess _access = DeviceFileAccess.unknown;
  List<DeviceRoot> _roots = <DeviceRoot>[];
  List<Map<String, dynamic>> _entries = <Map<String, dynamic>>[];
  String _currentPath = '';
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final String? root = context.read<PersonaStore>().workspaceRoot;
    _svc = widget.service ?? _buildService(root);
    _refresh();
  }

  DeviceFileService _buildService(String? root) {
    if (root == null || root.isEmpty) {
      return DeviceFileService(gateway: buildPlatformGateway());
    }
    return DeviceFileService(
      gateway: LocalDeviceFileGateway(<DeviceRoot>[
        DeviceRoot(root, '工作区域', writable: true),
      ]),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on Object catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() => _run(() async {
        _access = await _svc.accessState();
        _roots = _svc.roots;
        if (_access == DeviceFileAccess.granted && _currentPath.isNotEmpty) {
          await _list(_currentPath);
        }
      });

  Future<void> _request() => _run(() async {
        await _svc.requestAccess();
        await _refresh();
      });

  Future<void> _pickWorkspace() => _run(() async {
        final String? dir = await FilePicker.platform.getDirectoryPath();
        if (dir == null) return;
        final String real = Directory(dir).resolveSymbolicLinksSync();
        if (!mounted) return;
        context.read<PersonaStore>().setWorkspaceRoot(real);
        _svc = widget.service ?? _buildService(real);
        _currentPath = real;
        _entries = <Map<String, dynamic>>[];
      });

  Future<void> _clearWorkspace() => _run(() async {
        context.read<PersonaStore>().setWorkspaceRoot(null);
        _svc = widget.service ?? _buildService(null);
        _currentPath = '';
        _entries = <Map<String, dynamic>>[];
        await _refresh();
      });

  Future<void> _list(String path) async {
    final res = await _svc.dispatch('list', <String, dynamic>{'path': path});
    if (res.ok && res.data is List) {
      _entries = (res.data as List)
          .map((dynamic e) => Map<String, dynamic>.from(e as Map))
          .toList();
      _currentPath = path;
    } else {
      _error = res.error.isEmpty ? '读取目录失败' : res.error;
    }
  }

  Future<void> _openRoot(DeviceRoot root) => _run(() async {
        await _list(root.path);
      });

  Future<void> _delete(String path) => _run(() async {
        final res =
            await _svc.dispatch('delete', <String, dynamic>{'path': path});
        if (!res.ok) _error = res.error;
        await _list(_currentPath);
      });

  String get _accessLabel {
    switch (_access) {
      case DeviceFileAccess.granted:
        return '已授权';
      case DeviceFileAccess.denied:
        return '已拒绝';
      case DeviceFileAccess.needsSystemSettings:
        return '需到系统设置开启';
      case DeviceFileAccess.unknown:
        return '未检测';
    }
  }

  Color get _accessColor => _access == DeviceFileAccess.granted
      ? TangramColors.jade
      : TangramColors.warning;

  @override
  Widget build(BuildContext context) {
    final PersonaStore persona = context.watch<PersonaStore>();
    final SandboxStatus sandbox = context.watch<SandboxView>().status;
    final String? workspaceRoot = persona.workspaceRoot;
    return PanelPage(
      children: <Widget>[
        SectionTitle(
          title: '工作区域',
          subtitle: '只能访问你选定的文件夹',
          icon: Icons.folder_outlined,
          accent: TangramColors.jade,
          trailing: StatusPill(
            label: _accessLabel,
            color: _accessColor,
            dense: true,
          ),
        ),
        InfoTile(
          icon: Icons.folder_special_outlined,
          title: workspaceRoot == null || workspaceRoot.isEmpty
              ? '尚未选定隔离文件夹'
              : '隔离文件夹已选定',
          subtitle: workspaceRoot == null || workspaceRoot.isEmpty
              ? '内置沙箱可写根：${sandbox.writableSummary}'
              : workspaceRoot,
          color: workspaceRoot == null || workspaceRoot.isEmpty
              ? TangramColors.warning
              : TangramColors.jade,
        ),
        const SizedBox(height: TangramSpacing.sm),
        InfoTile(
          icon: Icons.security_outlined,
          title: '存储权限',
          subtitle: _access == DeviceFileAccess.granted
              ? '已授权 · 越界访问会被拦下'
              : '开启后可浏览设备文件',
          color: _accessColor,
        ),
        const SizedBox(height: TangramSpacing.lg),
        Wrap(
          spacing: TangramSpacing.md,
          runSpacing: TangramSpacing.sm,
          children: <Widget>[
            FilledButton.icon(
              onPressed: _busy ? null : _pickWorkspace,
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              label: const Text('选定隔离文件夹'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _request,
              icon: const Icon(Icons.lock_open_outlined, size: 18),
              label: const Text('申请文件访问'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _refresh,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('刷新状态'),
            ),
            if (workspaceRoot != null && workspaceRoot.isNotEmpty)
              TextButton.icon(
                onPressed: _busy ? null : _clearWorkspace,
                icon: const Icon(Icons.close, size: 16),
                label: const Text('取消隔离'),
              ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: TangramSpacing.md),
            child: Text(
              _error!,
              style: const TextStyle(color: TangramColors.danger, fontSize: 12),
            ),
          ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: TangramSpacing.lg),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        const SizedBox(height: TangramSpacing.xl),
        if (_access == DeviceFileAccess.granted) ...<Widget>[
          const SectionTitle(
            title: '可访问根目录',
            subtitle: '选择一个目录开始浏览',
            icon: Icons.storage_outlined,
          ),
          ..._roots.map(
            (DeviceRoot r) => Padding(
              padding: const EdgeInsets.only(bottom: TangramSpacing.sm),
              child: InfoTile(
                icon: Icons.folder_outlined,
                title: r.label,
                subtitle: r.path,
                color: TangramColors.jade,
                onTap: () => _openRoot(r),
              ),
            ),
          ),
          if (_currentPath.isNotEmpty) ...<Widget>[
            const SizedBox(height: TangramSpacing.xl),
            SectionTitle(
              title: '当前目录',
              subtitle: _currentPath,
              icon: Icons.list_alt_outlined,
            ),
            if (_entries.isEmpty)
              const GlassCard(
                child: EmptyState(
                  icon: Icons.folder_off_outlined,
                  title: '目录为空',
                  message: '这里暂时没有文件',
                  compact: true,
                ),
              )
            else
              ..._entries.map(_entryTile),
          ],
        ],
      ],
    );
  }

  Widget _entryTile(Map<String, dynamic> e) {
    final bool isDir = e['is_directory'] == true;
    final String name = (e['name'] ?? '').toString();
    final int size = (e['size'] ?? 0) as int;
    final String path = (e['path'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.only(bottom: TangramSpacing.sm),
      child: InfoTile(
        icon: isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
        title: name,
        subtitle: isDir ? '目录' : '$size 字节',
        color: isDir ? TangramColors.gold : TangramColors.accent,
        trailing: isDir
            ? IconButton(
                icon: const Icon(Icons.arrow_forward_ios, size: 14),
                onPressed: () => _openRoot(DeviceRoot(path, name)),
              )
            : IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: '移入隔离区',
                onPressed: () => _delete(path),
              ),
      ),
    );
  }
}
