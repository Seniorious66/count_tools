import 'package:flutter/material.dart';
import '../../data/database/data_base.dart';
import '../data/record_store.dart';
import '../../value/info.dart';
import 'catalog_pages.dart';
import 'components.dart';
import 'record_pages.dart';

/// M1 exposes working home/records; legacy projects remain in management.
class ChekiAppShell extends StatelessWidget {
  const ChekiAppShell({super.key});
  @override
  Widget build(BuildContext context) {
    final store = RecordStore(() => DatabaseHelper().database);
    return ChekiShell(
      destinations: [
        ChekiDestination(
          id: 'home',
          label: '首页',
          icon: Icons.home_outlined,
          page: RecordHomePage(store: store),
        ),
        ChekiDestination(
          id: 'records',
          label: '记录',
          icon: Icons.notes,
          page: RecordListPage(store: store, embedded: true),
        ),
      ],
      onManage: () async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => CatalogManagementPage()),
        );
        RecordStore.invalidateReads();
      },
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
