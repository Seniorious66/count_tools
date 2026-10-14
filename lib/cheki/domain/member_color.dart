/// Member colors are opaque RGB. Invalid or transparent legacy values stay unknown.
int? parseMemberHex(String value) {
  var text = value.trim();
  if (text.startsWith('#')) text = text.substring(1);
  if (RegExp(r'^[0-9a-fA-F]{3}$').hasMatch(text)) {
    text = text.split('').map((c) => '$c$c').join();
  }
  return RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(text)
      ? int.parse(text, radix: 16)
      : null;
}

int? parseMemberChannel(String value) {
  if (!RegExp(r'^\d{1,3}$').hasMatch(value.trim())) return null;
  final channel = int.parse(value.trim());
  return channel <= 255 ? channel : null;
}

String memberHex(int rgb) {
  if (rgb < 0 || rgb > 0xffffff) throw RangeError.range(rgb, 0, 0xffffff);
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

int? parseLegacyMemberColor(String? value) {
  if (value == null) return null;
  final text = value.trim();
  if (text.startsWith('#')) {
    if (RegExp(r'^#[fF]{2}[0-9a-fA-F]{6}$').hasMatch(text)) {
      return int.parse(text.substring(3), radix: 16);
    }
    return parseMemberHex(text);
  }
  if (!RegExp(r'^-?\d+$').hasMatch(text)) return null;
  final number = int.tryParse(text);
  if (number == null || number < -0x80000000 || number > 0xffffffff) {
    return null;
  }
  if (number >= 0 && number <= 0xffffff) return number;
  final argb = number & 0xffffffff;
  return argb >> 24 == 255 ? argb & 0xffffff : null;
}

const memberColorPresets = <String, int>{
  '红色': 0xff0000,
  '粉色': 0xff1889,
  '橙色': 0xff9800,
  '黄色': 0xffeb3b,
  '绿色': 0x4caf50,
  '蓝色': 0x2196f3,
  '紫色': 0x9c27b0,
  '黑色': 0x000000,
  '白色': 0xffffff,
};
