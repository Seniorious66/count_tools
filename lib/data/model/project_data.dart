/// A view of legacy values. Display fallbacks never overwrite stored NULLs.
class ProjectData {
  final Map<String, dynamic> _raw;

  ProjectData({
    required String id,
    required String title,
    required String subTitle,
    required String count,
    required String ext,
  }) : _raw = {
         'id': id,
         'title': title,
         'subTitle': subTitle,
         'count': count,
         'ext': ext,
       };

  ProjectData.fromJson(Map<String, dynamic> json) : _raw = Map.of(json);

  ProjectData copyWith({
    String? id,
    String? title,
    String? subTitle,
    String? count,
    String? ext,
  }) {
    final values = Map<String, dynamic>.of(_raw);
    if (id != null && id != this.id) {
      values['id'] = id;
    }
    if (title != null && title != this.title) {
      values['title'] = title;
    }
    if (subTitle != null && subTitle != this.subTitle) {
      values['subTitle'] = subTitle;
    }
    if (count != null && count != this.count) {
      values['count'] = count;
    }
    if (ext != null && ext != this.ext) {
      values['ext'] = ext;
    }
    return ProjectData.fromJson(values);
  }

  String get id => _raw['id']?.toString() ?? '';
  String get title => _raw['title']?.toString() ?? '';
  String get subTitle => _raw['subTitle']?.toString() ?? '';
  String get count => _raw['count']?.toString() ?? '';
  String get ext => _raw['ext']?.toString() ?? '';

  Map<String, dynamic> toJson() => Map.of(_raw);
}
