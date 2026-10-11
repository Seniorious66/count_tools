import 'package:flutter/material.dart';
import '../../page/home_page/home_page.dart';
import '../../value/info.dart';
import 'catalog_pages.dart';
import 'components.dart';

/// Only working destinations are registered. v1.2.1 replaces the compatibility
/// project destination with actual Cheki home/records after its services exist.
class ChekiAppShell extends StatelessWidget {
  const ChekiAppShell({super.key});
  @override
  Widget build(BuildContext context) => ChekiShell(
    destinations: const [
      ChekiDestination(
        id: 'legacy-projects',
        label: '旧版项目',
        icon: Icons.folder_outlined,
        page: HomePage(title: '旧版项目', embedded: true),
      ),
    ],
    onManage: () => Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => CatalogManagementPage())),
    actions: [
      IconButton(
        tooltip: '打开设置',
        icon: const Icon(Icons.settings),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const ChekiSettingsPage()),
        ),
      ),
    ],
  );
}

class ChekiSettingsPage extends StatelessWidget {
  const ChekiSettingsPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('设置')),
    body: SafeArea(
      top: false,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const ChekiCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('版本'),
                SizedBox(height: 8),
                Text('${AppInfo.appVersion} (${AppInfo.versionCode})'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          ChekiCard(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('关于'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showAboutDialog(
                context: context,
                applicationName: 'Cheki账本',
                applicationVersion:
                    '${AppInfo.appVersion} (${AppInfo.versionCode})',
                applicationLegalese:
                    '基于 fmqwd/count_tools 的个人客制化项目。\n沿用 Apache License 2.0。\n原作者 Copyright © 2024 fmqwd。',
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
