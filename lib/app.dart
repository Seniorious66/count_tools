import 'package:count_tools/page/home_page/home_page.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:count_tools/utils/setting_utils.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class App extends StatefulWidget {
  const App({super.key});

  @override
  AppState createState() => AppState();
}

class AppState extends State<App> {
  MaterialColor _themeColor = Colors.blue;
  late Future<void> _ready;

  @override
  void initState() {
    super.initState();
    _ready = _initApp();
  }

  Future<void> _loadThemeColor() async {
    MaterialColor color = await SettingUtils.getThemeColor();
    if (mounted) setState(() => _themeColor = color);
  }

  Future<void> _initApp() async {
    // Validate/migrate before any screen or preference initialization can write.
    await DatabaseHelper().database;
    await _loadThemeColor();
    if (!await SettingUtils.isNotFirstEnter()) {
      final prefs = await SharedPreferences.getInstance();
      if (!prefs.containsKey('projectInfoRowNum')) {
        await SettingUtils.setProjectInfoRowNum(5);
      }
      if (!prefs.containsKey('projectInfoSort')) {
        await SettingUtils.setProjectInfoSort('降序');
      }
      if (!prefs.containsKey('showMode')) {
        await SettingUtils.setShowMode('数量-百分比');
      }
      if (!prefs.containsKey('isShowTotalPrice')) {
        await SettingUtils.setIsShowTotalPrice(true);
      }
      await SettingUtils.setIsNotFirstEnter();
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Cheki账本',
    theme: ThemeData(primarySwatch: _themeColor),
    home: FutureBuilder<void>(
      future: _ready,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Scaffold(
            body: Center(
              child: Text(
                '数据校验未通过，已停止打开账本。\n请保留原备份并检查数据版本或关联。',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return const HomePage(title: '首页');
      },
    ),
  );
}
