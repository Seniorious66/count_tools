/// A view of legacy values. Display fallbacks never overwrite stored NULLs.
class ItemData {
  final Map<String, dynamic> _raw;

  ItemData({
    required String id,
    required String price,
    required String eventName,
    required String type,
    required String date,
    required String itemName,
    required String parentId,
    required String projectId,
    required String ext,
  }) : _raw = {
         'id': id,
         'price': price,
         'eventName': eventName,
         'type': type,
         'date': date,
         'itemName': itemName,
         'parentId': parentId,
         'projectId': projectId,
         'ext': ext,
       };

  ItemData.fromJson(Map<String, dynamic> json) : _raw = Map.of(json);

  ItemData copyWith({
    String? id,
    String? price,
    String? eventName,
    String? type,
    String? date,
    String? itemName,
    String? parentId,
    String? projectId,
    String? ext,
  }) {
    final values = Map<String, dynamic>.of(_raw);
    if (id != null && id != this.id) {
      values['id'] = id;
    }
    if (price != null && price != this.price) {
      values['price'] = price;
    }
    if (eventName != null && eventName != this.eventName) {
      values['eventName'] = eventName;
    }
    if (type != null && type != this.type) {
      values['type'] = type;
    }
    if (date != null && date != this.date) {
      values['date'] = date;
    }
    if (itemName != null && itemName != this.itemName) {
      values['itemName'] = itemName;
    }
    if (parentId != null && parentId != this.parentId) {
      values['parentId'] = parentId;
    }
    if (projectId != null && projectId != this.projectId) {
      values['projectId'] = projectId;
    }
    if (ext != null && ext != this.ext) {
      values['ext'] = ext;
    }
    return ItemData.fromJson(values);
  }

  String get id => _raw['id']?.toString() ?? '';
  String get price => _raw['price']?.toString() ?? '';
  String get eventName => _raw['eventName']?.toString() ?? '';
  String get type => _raw['type']?.toString() ?? '';
  String get date => _raw['date']?.toString() ?? '';
  String get itemName => _raw['itemName']?.toString() ?? '';
  String get parentId => _raw['parentId']?.toString() ?? '';
  String get projectId => _raw['projectId']?.toString() ?? '';
  String get ext => _raw['ext']?.toString() ?? '';

  Map<String, dynamic> toJson() => Map.of(_raw);
}
