import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/workspace_provider.dart';
import '../../../core/services/workspace/models.dart';

/// Workspace management page: list, create, delete, install rootfs.
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

  Future<void> _deleteWorkspace(Workspace ws) async {
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
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WorkspaceProvider>();
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
          if (provider.workspaces.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Icon(Icons.folder_open,
                        size: 40, color: cs.onSurfaceVariant),
                    const SizedBox(height: 8),
                    Text('还没有工作区', style: TextStyle(color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
            )
          else
            ...provider.workspaces.map((ws) => _WorkspaceCard(
                  workspace: ws,
                  onInstall: () => _installRootfs(ws),
                  onDelete: () => _deleteWorkspace(ws),
                )),
        ],
      ),
    );
  }
}

class _WorkspaceCard extends StatelessWidget {
  const _WorkspaceCard({
    required this.workspace,
    required this.onInstall,
    required this.onDelete,
  });

  final Workspace workspace;
  final VoidCallback onInstall;
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
                if (workspace.shellStatus != WorkspaceShellStatus.ready)
                  FilledButton.tonalIcon(
                    onPressed: workspace.shellStatus ==
                            WorkspaceShellStatus.installing
                        ? null
                        : onInstall,
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('安装 Rootfs'),
                  ),
                if (workspace.shellStatus == WorkspaceShellStatus.ready)
                  FilledButton.tonalIcon(
                    onPressed: null,
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('已就绪'),
                  ),
                const Spacer(),
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
