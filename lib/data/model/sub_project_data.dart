/// A view of legacy values. Display fallbacks never overwrite stored NULLs.
class SubProjectData {
  final Map<String, dynamic> _raw;

  SubProjectData({
    required String id,
    required String name,
    required String count,
    required String countPre,
    required String color,
    required String textColor,
    required String parentId,
    required String ext,
  }) : _raw = {
         'id': id,
         'name': name,
         'count': count,
         'countPre': countPre,
         'color': color,
         'textColor': textColor,
         'parentId': parentId,
         'ext': ext,
       };

  SubProjectData.fromJson(Map<String, dynamic> json) : _raw = Map.of(json);

  SubProjectData copyWith({
    String? id,
    String? name,
    String? count,
    String? countPre,
    String? color,
    String? textColor,
    String? parentId,
    String? ext,
  }) {
    final values = Map<String, dynamic>.of(_raw);
    if (id != null && id != this.id) {
      values['id'] = id;
    }
    if (name != null && name != this.name) {
      values['name'] = name;
    }
    if (count != null && count != this.count) {
      values['count'] = count;
    }
    if (countPre != null && countPre != this.countPre) {
      values['countPre'] = countPre;
    }
    if (color != null && color != this.color) {
      values['color'] = color;
    }
    if (textColor != null && textColor != this.textColor) {
      values['textColor'] = textColor;
    }
    if (parentId != null && parentId != this.parentId) {
      values['parentId'] = parentId;
    }
    if (ext != null && ext != this.ext) {
      values['ext'] = ext;
    }
    return SubProjectData.fromJson(values);
  }

  String get id => _raw['id']?.toString() ?? '';
  String get name => _raw['name']?.toString() ?? '';
  String get count => _raw['count']?.toString() ?? '';
  String get countPre => _raw['countPre']?.toString() ?? '';
  String get color => _raw['color']?.toString() ?? '';
  String get textColor => _raw['textColor']?.toString() ?? '';
  String get parentId => _raw['parentId']?.toString() ?? '';
  String get ext => _raw['ext']?.toString() ?? '';

  Map<String, dynamic> toJson() => Map.of(_raw);
}
