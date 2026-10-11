import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

bool _registered = false;

void registerSourceLicense() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString(
      'assets/licenses/count_tools.txt',
    );
    yield LicenseEntryWithLineBreaks([
      'count_tools',
    ], 'Source: fmqwd/count_tools\nCopyright © 2024 fmqwd\n\n$license');
  });
}
