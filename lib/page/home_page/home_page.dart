import 'package:count_tools/page/component/list_item/single_project_widget.dart';
import 'package:count_tools/page/custom_widget/remove_padding_widget.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'home_page_vm.dart';
import '../../cheki/ui/catalog_pages.dart';

class HomePage extends StatefulWidget {
  final String title;
  final bool embedded;

  const HomePage({super.key, required this.title, this.embedded = false});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late HomePageViewModel _vm;

  @override
  void initState() {
    super.initState();
    _vm = HomePageViewModel()..loadProjects();
  }

  @override
  void dispose() {
    _vm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider.value(
    value: _vm,
    child: widget.embedded
        ? Stack(
            children: [
              Center(child: _buildHomePageProjectList()),
              Positioned(right: 16, bottom: 16, child: _addButton()),
            ],
          )
        : Scaffold(
            appBar: AppBar(
              title: Text(widget.title),
              actions: [
                IconButton(
                  icon: const Icon(Icons.tune),
                  tooltip: 'Cheki 管理',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => CatalogManagementPage(),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.settings),
                  onPressed: () => _vm.pushSetPage(context),
                ),
              ],
            ),
            body: Center(child: _buildHomePageProjectList()),
            floatingActionButton: _addButton(),
          ),
  );

  Widget _addButton() => Builder(
    builder: (context) => FloatingActionButton(
      tooltip: '新增项目',
      key: const Key('add_project_btn'),
      child: const Icon(Icons.add),
      onPressed: () => _vm.addProjectDialog(context),
    ),
  );

  Widget _buildHomePageProjectList() => Consumer<HomePageViewModel>(
    builder: (context, vm, _) {
      if (vm.loading) return const Center(child: CircularProgressIndicator());
      if (vm.loadFailed) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('读取项目失败，请重试'),
              TextButton(onPressed: _vm.loadProjects, child: const Text('重试')),
            ],
          ),
        );
      }
      if (vm.projects.isEmpty) {
        return const Center(child: Text('没有项目，点击+添加'));
      }
      return NonePaddingWidget(
        context: context,
        child: RefreshIndicator(
          onRefresh: _vm.loadProjects,
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: vm.projects.length,
            itemBuilder: (context, index) => SingleProjectWidget(
              project: vm.projects[index],
              onDelete: () =>
                  vm.delProjectDialog(context, vm.projects[index].id),
              onClick: () =>
                  vm.pushProjectInfoPage(context, vm.projects[index]),
              onEdit: () => vm.editProjectDialog(context, vm.projects[index]),
            ),
          ),
        ),
      );
    },
  );
}
