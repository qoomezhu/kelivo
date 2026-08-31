import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/workspace_provider.dart';
import '../../../core/services/workspace/models.dart';

/// Workspace management page: enable the agent workspace, pick the active
/// root, create/delete workspaces, install/uninstall the rootfs.
///
/// UI follows kelivo's settings page conventions (SectionCard + list rows).
class WorkspacePage extends StatefulWidget {
  const WorkspacePage({super.key});

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<WorkspaceProvider>().load();
    });
  }

  Future<void> _createWorkspace() async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建工作区'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '名称',
            hintText: '例如: my-agent',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final name = controller.text.trim();
    if (name.isEmpty) return;
    try {
      await context.read<WorkspaceProvider>().create(name);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('创建失败: $e')),
        );
      }
    }
  }

  Future<void> _installRootfs(Workspace ws) async {
    final provider = context.read<WorkspaceProvider>();
    try {
      await provider.installRootfs(ws.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('「${ws.name}」Rootfs 安装完成')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Rootfs 安装失败: $e')),
        );
      }
    }
  }

  Future<void> _uninstallRootfs(Workspace ws) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('卸载 Rootfs'),
        content: Text('「${ws.name}」的 Rootfs 将被删除，文件区保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await context.read<WorkspaceProvider>().uninstallRootfs(ws.id);
  }

  Future<void> _deleteWorkspace(Workspace ws) async {
    final settings = context.read<SettingsProvider>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除工作区'),
        content: Text(
          '将删除「${ws.name}」的全部文件和 Rootfs，无法恢复。确定继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await context.read<WorkspaceProvider>().delete(ws.id);
    // 清掉引用，避免 settings 指向已删除的 root
    if (settings.workspaceActiveRoot == ws.root) {
      await settings.setWorkspaceActiveRoot(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WorkspaceProvider>();
    final settings = context.watch<SettingsProvider>();
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('工作区')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createWorkspace,
        icon: const Icon(Icons.add),
        label: const Text('新建'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
        children: [
          Text(
            '轻量化 Agent 的 Linux 工作区。安装 Rootfs 后，助手可以在'
            '沙箱内执行命令、读写文件。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            title: const Text('启用工作区 Agent'),
            subtitle: const Text('会话中暴露 workspace_read/write/edit/shell 工具'),
            value: settings.workspaceAgentEnabled,
            onChanged: (v) => settings.setWorkspaceAgentEnabled(v),
          ),
          const SizedBox(height: 8),
          if (settings.workspaceAgentEnabled)
            Text(
              "当前工作区: ${settings.workspaceActiveRoot ?? '（未选择）'}",
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
            ),
          const SizedBox(height: 8),
          if (provider.workspaces.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Icon(Icons.folder_open,
                        size: 40, color: cs.onSurfaceVariant),
                    const SizedBox(height: 8),
                    Text('还没有工作区',
                        style: TextStyle(color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
            )
          else
            ...provider.workspaces.map(
              (ws) => _WorkspaceCard(
                workspace: ws,
                isActive: settings.workspaceActiveRoot == ws.root,
                canActivate:
                    settings.workspaceAgentEnabled &&
                    ws.shellStatus == WorkspaceShellStatus.ready,
                onActivate: () =>
                    settings.setWorkspaceActiveRoot(ws.root),
                onInstall: () => _installRootfs(ws),
                onUninstall: () => _uninstallRootfs(ws),
                onDelete: () => _deleteWorkspace(ws),
              ),
            ),
        ],
      ),
    );
  }
}

class _WorkspaceCard extends StatelessWidget {
  const _WorkspaceCard({
    required this.workspace,
    required this.isActive,
    required this.canActivate,
    required this.onActivate,
    required this.onInstall,
    required this.onUninstall,
    required this.onDelete,
  });

  final Workspace workspace;
  final bool isActive;
  final bool canActivate;
  final VoidCallback onActivate;
  final VoidCallback onInstall;
  final VoidCallback onUninstall;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (label, color) = switch (workspace.shellStatus) {
      WorkspaceShellStatus.ready => ('就绪', Colors.green),
      WorkspaceShellStatus.installing => ('安装中…', Colors.orange),
      WorkspaceShellStatus.broken => ('异常', Colors.red),
      WorkspaceShellStatus.disabled => ('未安装 Rootfs', Colors.grey),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    workspace.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 12, color: color),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '根目录: ${workspace.root}',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (workspace.shellStatus == WorkspaceShellStatus.ready)
                  FilledButton.tonalIcon(
                    onPressed: canActivate && !isActive ? onActivate : null,
                    icon: Icon(
                      isActive ? Icons.check_circle : Icons.play_arrow,
                      size: 18,
                    ),
                    label: Text(isActive ? '使用中' : '设为当前'),
                  )
                else
                  FilledButton.tonalIcon(
                    onPressed: workspace.shellStatus ==
                            WorkspaceShellStatus.installing
                        ? null
                        : onInstall,
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('安装 Rootfs'),
                  ),
                const Spacer(),
                if (workspace.shellStatus == WorkspaceShellStatus.ready)
                  IconButton(
                    onPressed: onUninstall,
                    icon: const Icon(Icons.layers_clear, size: 20),
                    tooltip: '卸载 Rootfs',
                  ),
                IconButton(
                  onPressed: onDelete,
                  icon: Icon(Icons.delete_outline, color: cs.error),
                  tooltip: '删除',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
