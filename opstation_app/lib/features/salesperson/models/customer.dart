/// Customer / shop that can appear on a route.
class Customer {
  final String id;
  final String code;
  final String shopName;
  final String contactPerson;
  final String phone;
  final String address;
  final String? category;
  final String? group;
  final double? latitude;
  final double? longitude;
  final bool isActive;
  final DateTime? updatedAt;
  final String? ntnGst;

  const Customer({
    required this.id,
    required this.code,
    required this.shopName,
    required this.contactPerson,
    required this.phone,
    required this.address,
    this.category,
    this.group,
    this.latitude,
    this.longitude,
    this.isActive = true,
    this.updatedAt,
    this.ntnGst,
  });

  bool get hasLocation => latitude != null && longitude != null;

  String get initials {
    final parts =
        shopName.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts[1].substring(0, 1))
        .toUpperCase();
  }

  Customer copyWith({
    String? id,
    String? code,
    String? shopName,
    String? contactPerson,
    String? phone,
    String? address,
    String? category,
    bool clearCategory = false,
    String? group,
    bool clearGroup = false,
    double? latitude,
    double? longitude,
    bool clearLocation = false,
    bool? isActive,
    DateTime? updatedAt,
    String? ntnGst,
    bool clearNtnGst = false,
  }) {
    return Customer(
      id: id ?? this.id,
      code: code ?? this.code,
      shopName: shopName ?? this.shopName,
      contactPerson: contactPerson ?? this.contactPerson,
      phone: phone ?? this.phone,
      address: address ?? this.address,
      category: clearCategory ? null : (category ?? this.category),
      group: clearGroup ? null : (group ?? this.group),
      latitude: clearLocation ? null : (latitude ?? this.latitude),
      longitude: clearLocation ? null : (longitude ?? this.longitude),
      isActive: isActive ?? this.isActive,
      updatedAt: updatedAt ?? this.updatedAt,
      ntnGst: clearNtnGst ? null : (ntnGst ?? this.ntnGst),
    );
  }
}
