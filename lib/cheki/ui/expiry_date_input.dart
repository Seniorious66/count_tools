import '../domain/record_contract.dart';

/// The form uses YYMMDD; storage and pool keys keep the complete business date.
String expiryInputText(String? date) {
  if (date == null) return '';
  return date.startsWith('20') ? date.substring(2).replaceAll('-', '') : date;
}

String? parseExpiryInput(
  String text, {
  String? original,
  String label = '截止日',
}) {
  if (text == expiryInputText(original)) return original;
  if (text.isEmpty) return null;
  if (text.length != 6 || !RegExp(r'^[0-9]{6}$').hasMatch(text)) {
    throw FormatException('$label请输入六位数字 YYMMDD，例如 261231');
  }
  final date =
      '20${text.substring(0, 2)}-${text.substring(2, 4)}-${text.substring(4)}';
  try {
    return OccurredOn.parse(date).value;
  } on FormatException {
    throw FormatException('$label不是有效日期，请检查月份和日');
  }
}
