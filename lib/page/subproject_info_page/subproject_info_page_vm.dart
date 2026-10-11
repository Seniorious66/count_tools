import 'package:count_tools/data/database/helper/item_helper.dart';
import 'package:count_tools/data/database/helper/sub_project_helper.dart';
import 'package:count_tools/data/model/item_data.dart';
import 'package:count_tools/data/model/sub_project_data.dart';
import 'package:count_tools/page/dialog/loading_dialog.dart';
import 'package:count_tools/page/dialog/subproject_info_setting_dialog.dart';
import 'package:count_tools/utils/setting_utils.dart';
import 'package:flutter/material.dart';

class SubProjectInfoViewModel extends ChangeNotifier {
  final ItemDBHelper itemDBHelper = ItemDBHelper();
  final SubProjectDbHelper subProjectDbHelper = SubProjectDbHelper();

  List<ItemData> _items = [];
  List<ItemData> get items => _items;

  List<String> _dates = [];
  List<String> get dates => _dates;

  String _cost = '';
  String get cost => _cost;

  bool _isShowPrice = true;
  bool get isShowPrice => _isShowPrice;

  Future<void> loadItems(String parentId) async {
    await _loadShared();
    _items = await itemDBHelper.getByParent(parentId);
    _dates = _items.map((e) => e.date).toSet().toList();
    loadCost();
    notifyListeners();
  }

  Future<void> _loadShared() async {
    _isShowPrice = await SettingUtils.getIsShowTotalPrice();
    notifyListeners();
  }

  void loadCost() {
    double mCost = 0.0;
    int unknown = 0;
    for (ItemData item in items) {
      final value = double.tryParse(item.price);
      if (value == null || !value.isFinite) {
        unknown++;
      } else {
        mCost += value;
      }
    }
    _cost = unknown == 0 ? mCost.toString() : '$mCost（另有$unknown条金额未知）';
  }

  Future<void> addItem(ItemData data) async {
    await itemDBHelper.insert(data);
    await loadItems(data.parentId);
  }

  Future<void> addItems(List<ItemData> datas) async {
    await itemDBHelper.insertItems(datas);
    await loadItems(datas.first.parentId);
  }

  Future<void> editItem(ItemData data) async {
    await itemDBHelper.update(data);
    await loadItems(data.parentId);
  }

  Future<void> editItems(List<ItemData> datas) async {
    await itemDBHelper.updateAll(datas);
    await loadItems(datas.first.parentId);
  }

  Future<void> deleteItem(String id, String parentId) async {
    await itemDBHelper.delete(id);
    await loadItems(parentId);
  }

  Future<void> updateSubProject(SubProjectData data) async {
    await loadItems(data.id);
    SubProjectData dataUpdate = data.copyWith(count: (items.length).toString());
    await subProjectDbHelper.update(dataUpdate);
  }

  Future<void> addItemClickLess(
    SubProjectData data,
    int index,
    ItemData item,
    BuildContext context,
  ) async {
    final List<ItemData> items = List.generate(index, (_) => item);
    await addItems(items);
    await updateSubProject(data);
  }

  Future<void> addItemClick(
    SubProjectData data,
    int index,
    ItemData item,
    BuildContext context,
  ) async {
    if (index <= 100) {
      await addItemClickLess(data, index, item, context);
    } else {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const UpdatingProgressDialog("插入数据中……"),
      );
      final List<ItemData> items = List.generate(index, (_) => item);
      await addItems(items);
      await updateSubProject(data);
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> deleteItemClick(
    BuildContext context,
    SubProjectData data,
  ) async {
    if (items.isNotEmpty) {
      await deleteItem(items.last.id, data.id);
      await updateSubProject(data);
    }
  }

  void showSettingDialog(BuildContext context) =>
      showSubProjectInfoSettingDialog(context, () => _loadShared());
}
