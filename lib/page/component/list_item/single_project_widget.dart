import 'package:count_tools/data/model/project_data.dart';
import 'package:count_tools/cheki/ui/components.dart';
import 'package:flutter/material.dart';

class SingleProjectWidget extends StatelessWidget {
  final ProjectData project;
  final VoidCallback onClick;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const SingleProjectWidget({
    super.key,
    required this.project,
    required this.onDelete,
    required this.onClick,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: ChekiCard(
      child: InkWell(
        onTap: onClick,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: Text(
                    project.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    project.count,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            if (project.subTitle.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                project.subTitle,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: '删除项目',
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline),
                ),
                IconButton(
                  tooltip: '修改项目',
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
