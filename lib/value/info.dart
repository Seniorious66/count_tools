class AppInfo {
  static const String appVersion = String.fromEnvironment(
    'APP_VERSION_NAME',
    defaultValue: '0.0.0-m0.1',
  );
  static const int versionCode = int.fromEnvironment(
    'APP_VERSION_CODE',
    defaultValue: 11000,
  );
}
