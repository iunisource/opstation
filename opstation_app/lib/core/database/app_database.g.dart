// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $CustomersTable extends Customers
    with TableInfo<$CustomersTable, CustomersData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CustomersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _codeMeta = const VerificationMeta('code');
  @override
  late final GeneratedColumn<String> code = GeneratedColumn<String>(
      'code', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _shopNameMeta =
      const VerificationMeta('shopName');
  @override
  late final GeneratedColumn<String> shopName = GeneratedColumn<String>(
      'shop_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _contactPersonMeta =
      const VerificationMeta('contactPerson');
  @override
  late final GeneratedColumn<String> contactPerson = GeneratedColumn<String>(
      'contact_person', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _phoneMeta = const VerificationMeta('phone');
  @override
  late final GeneratedColumn<String> phone = GeneratedColumn<String>(
      'phone', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _addressMeta =
      const VerificationMeta('address');
  @override
  late final GeneratedColumn<String> address = GeneratedColumn<String>(
      'address', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _categoryMeta =
      const VerificationMeta('category');
  @override
  late final GeneratedColumn<String> category = GeneratedColumn<String>(
      'category', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _groupNameMeta =
      const VerificationMeta('groupName');
  @override
  late final GeneratedColumn<String> groupName = GeneratedColumn<String>(
      'group_name', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _latitudeMeta =
      const VerificationMeta('latitude');
  @override
  late final GeneratedColumn<double> latitude = GeneratedColumn<double>(
      'latitude', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _longitudeMeta =
      const VerificationMeta('longitude');
  @override
  late final GeneratedColumn<double> longitude = GeneratedColumn<double>(
      'longitude', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _isActiveMeta =
      const VerificationMeta('isActive');
  @override
  late final GeneratedColumn<bool> isActive = GeneratedColumn<bool>(
      'is_active', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_active" IN (0, 1))'),
      defaultValue: const Constant(true));
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _ntnGstMeta = const VerificationMeta('ntnGst');
  @override
  late final GeneratedColumn<String> ntnGst = GeneratedColumn<String>(
      'ntn_gst', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _orgIdMeta = const VerificationMeta('orgId');
  @override
  late final GeneratedColumn<String> orgId = GeneratedColumn<String>(
      'org_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _syncStatusMeta =
      const VerificationMeta('syncStatus');
  @override
  late final GeneratedColumn<String> syncStatus = GeneratedColumn<String>(
      'sync_status', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('synced'));
  @override
  List<GeneratedColumn> get $columns => [
        id,
        code,
        shopName,
        contactPerson,
        phone,
        address,
        category,
        groupName,
        latitude,
        longitude,
        isActive,
        updatedAt,
        ntnGst,
        orgId,
        syncStatus
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'customers';
  @override
  VerificationContext validateIntegrity(Insertable<CustomersData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('code')) {
      context.handle(
          _codeMeta, code.isAcceptableOrUnknown(data['code']!, _codeMeta));
    } else if (isInserting) {
      context.missing(_codeMeta);
    }
    if (data.containsKey('shop_name')) {
      context.handle(_shopNameMeta,
          shopName.isAcceptableOrUnknown(data['shop_name']!, _shopNameMeta));
    } else if (isInserting) {
      context.missing(_shopNameMeta);
    }
    if (data.containsKey('contact_person')) {
      context.handle(
          _contactPersonMeta,
          contactPerson.isAcceptableOrUnknown(
              data['contact_person']!, _contactPersonMeta));
    } else if (isInserting) {
      context.missing(_contactPersonMeta);
    }
    if (data.containsKey('phone')) {
      context.handle(
          _phoneMeta, phone.isAcceptableOrUnknown(data['phone']!, _phoneMeta));
    } else if (isInserting) {
      context.missing(_phoneMeta);
    }
    if (data.containsKey('address')) {
      context.handle(_addressMeta,
          address.isAcceptableOrUnknown(data['address']!, _addressMeta));
    } else if (isInserting) {
      context.missing(_addressMeta);
    }
    if (data.containsKey('category')) {
      context.handle(_categoryMeta,
          category.isAcceptableOrUnknown(data['category']!, _categoryMeta));
    }
    if (data.containsKey('group_name')) {
      context.handle(_groupNameMeta,
          groupName.isAcceptableOrUnknown(data['group_name']!, _groupNameMeta));
    }
    if (data.containsKey('latitude')) {
      context.handle(_latitudeMeta,
          latitude.isAcceptableOrUnknown(data['latitude']!, _latitudeMeta));
    }
    if (data.containsKey('longitude')) {
      context.handle(_longitudeMeta,
          longitude.isAcceptableOrUnknown(data['longitude']!, _longitudeMeta));
    }
    if (data.containsKey('is_active')) {
      context.handle(_isActiveMeta,
          isActive.isAcceptableOrUnknown(data['is_active']!, _isActiveMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    if (data.containsKey('ntn_gst')) {
      context.handle(_ntnGstMeta,
          ntnGst.isAcceptableOrUnknown(data['ntn_gst']!, _ntnGstMeta));
    }
    if (data.containsKey('org_id')) {
      context.handle(
          _orgIdMeta, orgId.isAcceptableOrUnknown(data['org_id']!, _orgIdMeta));
    }
    if (data.containsKey('sync_status')) {
      context.handle(
          _syncStatusMeta,
          syncStatus.isAcceptableOrUnknown(
              data['sync_status']!, _syncStatusMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CustomersData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CustomersData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      code: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}code'])!,
      shopName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}shop_name'])!,
      contactPerson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}contact_person'])!,
      phone: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}phone'])!,
      address: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}address'])!,
      category: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}category']),
      groupName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}group_name']),
      latitude: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}latitude']),
      longitude: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}longitude']),
      isActive: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_active'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at']),
      ntnGst: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}ntn_gst']),
      orgId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}org_id']),
      syncStatus: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_status'])!,
    );
  }

  @override
  $CustomersTable createAlias(String alias) {
    return $CustomersTable(attachedDatabase, alias);
  }
}

class CustomersData extends DataClass implements Insertable<CustomersData> {
  final String id;
  final String code;
  final String shopName;
  final String contactPerson;
  final String phone;
  final String address;
  final String? category;
  final String? groupName;
  final double? latitude;
  final double? longitude;
  final bool isActive;
  final DateTime? updatedAt;
  final String? ntnGst;
  final String? orgId;

  /// Offline-first sync state: 'pending' (local edit awaiting push) | 'synced'.
  /// Defaults to 'synced' so rows pulled from the server are clean; local
  /// writes set 'pending' and flushPending pushes them like visits/deliveries.
  final String syncStatus;
  const CustomersData(
      {required this.id,
      required this.code,
      required this.shopName,
      required this.contactPerson,
      required this.phone,
      required this.address,
      this.category,
      this.groupName,
      this.latitude,
      this.longitude,
      required this.isActive,
      this.updatedAt,
      this.ntnGst,
      this.orgId,
      required this.syncStatus});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['code'] = Variable<String>(code);
    map['shop_name'] = Variable<String>(shopName);
    map['contact_person'] = Variable<String>(contactPerson);
    map['phone'] = Variable<String>(phone);
    map['address'] = Variable<String>(address);
    if (!nullToAbsent || category != null) {
      map['category'] = Variable<String>(category);
    }
    if (!nullToAbsent || groupName != null) {
      map['group_name'] = Variable<String>(groupName);
    }
    if (!nullToAbsent || latitude != null) {
      map['latitude'] = Variable<double>(latitude);
    }
    if (!nullToAbsent || longitude != null) {
      map['longitude'] = Variable<double>(longitude);
    }
    map['is_active'] = Variable<bool>(isActive);
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    if (!nullToAbsent || ntnGst != null) {
      map['ntn_gst'] = Variable<String>(ntnGst);
    }
    if (!nullToAbsent || orgId != null) {
      map['org_id'] = Variable<String>(orgId);
    }
    map['sync_status'] = Variable<String>(syncStatus);
    return map;
  }

  CustomersCompanion toCompanion(bool nullToAbsent) {
    return CustomersCompanion(
      id: Value(id),
      code: Value(code),
      shopName: Value(shopName),
      contactPerson: Value(contactPerson),
      phone: Value(phone),
      address: Value(address),
      category: category == null && nullToAbsent
          ? const Value.absent()
          : Value(category),
      groupName: groupName == null && nullToAbsent
          ? const Value.absent()
          : Value(groupName),
      latitude: latitude == null && nullToAbsent
          ? const Value.absent()
          : Value(latitude),
      longitude: longitude == null && nullToAbsent
          ? const Value.absent()
          : Value(longitude),
      isActive: Value(isActive),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
      ntnGst:
          ntnGst == null && nullToAbsent ? const Value.absent() : Value(ntnGst),
      orgId:
          orgId == null && nullToAbsent ? const Value.absent() : Value(orgId),
      syncStatus: Value(syncStatus),
    );
  }

  factory CustomersData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CustomersData(
      id: serializer.fromJson<String>(json['id']),
      code: serializer.fromJson<String>(json['code']),
      shopName: serializer.fromJson<String>(json['shopName']),
      contactPerson: serializer.fromJson<String>(json['contactPerson']),
      phone: serializer.fromJson<String>(json['phone']),
      address: serializer.fromJson<String>(json['address']),
      category: serializer.fromJson<String?>(json['category']),
      groupName: serializer.fromJson<String?>(json['groupName']),
      latitude: serializer.fromJson<double?>(json['latitude']),
      longitude: serializer.fromJson<double?>(json['longitude']),
      isActive: serializer.fromJson<bool>(json['isActive']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
      ntnGst: serializer.fromJson<String?>(json['ntnGst']),
      orgId: serializer.fromJson<String?>(json['orgId']),
      syncStatus: serializer.fromJson<String>(json['syncStatus']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'code': serializer.toJson<String>(code),
      'shopName': serializer.toJson<String>(shopName),
      'contactPerson': serializer.toJson<String>(contactPerson),
      'phone': serializer.toJson<String>(phone),
      'address': serializer.toJson<String>(address),
      'category': serializer.toJson<String?>(category),
      'groupName': serializer.toJson<String?>(groupName),
      'latitude': serializer.toJson<double?>(latitude),
      'longitude': serializer.toJson<double?>(longitude),
      'isActive': serializer.toJson<bool>(isActive),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
      'ntnGst': serializer.toJson<String?>(ntnGst),
      'orgId': serializer.toJson<String?>(orgId),
      'syncStatus': serializer.toJson<String>(syncStatus),
    };
  }

  CustomersData copyWith(
          {String? id,
          String? code,
          String? shopName,
          String? contactPerson,
          String? phone,
          String? address,
          Value<String?> category = const Value.absent(),
          Value<String?> groupName = const Value.absent(),
          Value<double?> latitude = const Value.absent(),
          Value<double?> longitude = const Value.absent(),
          bool? isActive,
          Value<DateTime?> updatedAt = const Value.absent(),
          Value<String?> ntnGst = const Value.absent(),
          Value<String?> orgId = const Value.absent(),
          String? syncStatus}) =>
      CustomersData(
        id: id ?? this.id,
        code: code ?? this.code,
        shopName: shopName ?? this.shopName,
        contactPerson: contactPerson ?? this.contactPerson,
        phone: phone ?? this.phone,
        address: address ?? this.address,
        category: category.present ? category.value : this.category,
        groupName: groupName.present ? groupName.value : this.groupName,
        latitude: latitude.present ? latitude.value : this.latitude,
        longitude: longitude.present ? longitude.value : this.longitude,
        isActive: isActive ?? this.isActive,
        updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
        ntnGst: ntnGst.present ? ntnGst.value : this.ntnGst,
        orgId: orgId.present ? orgId.value : this.orgId,
        syncStatus: syncStatus ?? this.syncStatus,
      );
  CustomersData copyWithCompanion(CustomersCompanion data) {
    return CustomersData(
      id: data.id.present ? data.id.value : this.id,
      code: data.code.present ? data.code.value : this.code,
      shopName: data.shopName.present ? data.shopName.value : this.shopName,
      contactPerson: data.contactPerson.present
          ? data.contactPerson.value
          : this.contactPerson,
      phone: data.phone.present ? data.phone.value : this.phone,
      address: data.address.present ? data.address.value : this.address,
      category: data.category.present ? data.category.value : this.category,
      groupName: data.groupName.present ? data.groupName.value : this.groupName,
      latitude: data.latitude.present ? data.latitude.value : this.latitude,
      longitude: data.longitude.present ? data.longitude.value : this.longitude,
      isActive: data.isActive.present ? data.isActive.value : this.isActive,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      ntnGst: data.ntnGst.present ? data.ntnGst.value : this.ntnGst,
      orgId: data.orgId.present ? data.orgId.value : this.orgId,
      syncStatus:
          data.syncStatus.present ? data.syncStatus.value : this.syncStatus,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CustomersData(')
          ..write('id: $id, ')
          ..write('code: $code, ')
          ..write('shopName: $shopName, ')
          ..write('contactPerson: $contactPerson, ')
          ..write('phone: $phone, ')
          ..write('address: $address, ')
          ..write('category: $category, ')
          ..write('groupName: $groupName, ')
          ..write('latitude: $latitude, ')
          ..write('longitude: $longitude, ')
          ..write('isActive: $isActive, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('ntnGst: $ntnGst, ')
          ..write('orgId: $orgId, ')
          ..write('syncStatus: $syncStatus')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      code,
      shopName,
      contactPerson,
      phone,
      address,
      category,
      groupName,
      latitude,
      longitude,
      isActive,
      updatedAt,
      ntnGst,
      orgId,
      syncStatus);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CustomersData &&
          other.id == this.id &&
          other.code == this.code &&
          other.shopName == this.shopName &&
          other.contactPerson == this.contactPerson &&
          other.phone == this.phone &&
          other.address == this.address &&
          other.category == this.category &&
          other.groupName == this.groupName &&
          other.latitude == this.latitude &&
          other.longitude == this.longitude &&
          other.isActive == this.isActive &&
          other.updatedAt == this.updatedAt &&
          other.ntnGst == this.ntnGst &&
          other.orgId == this.orgId &&
          other.syncStatus == this.syncStatus);
}

class CustomersCompanion extends UpdateCompanion<CustomersData> {
  final Value<String> id;
  final Value<String> code;
  final Value<String> shopName;
  final Value<String> contactPerson;
  final Value<String> phone;
  final Value<String> address;
  final Value<String?> category;
  final Value<String?> groupName;
  final Value<double?> latitude;
  final Value<double?> longitude;
  final Value<bool> isActive;
  final Value<DateTime?> updatedAt;
  final Value<String?> ntnGst;
  final Value<String?> orgId;
  final Value<String> syncStatus;
  final Value<int> rowid;
  const CustomersCompanion({
    this.id = const Value.absent(),
    this.code = const Value.absent(),
    this.shopName = const Value.absent(),
    this.contactPerson = const Value.absent(),
    this.phone = const Value.absent(),
    this.address = const Value.absent(),
    this.category = const Value.absent(),
    this.groupName = const Value.absent(),
    this.latitude = const Value.absent(),
    this.longitude = const Value.absent(),
    this.isActive = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.ntnGst = const Value.absent(),
    this.orgId = const Value.absent(),
    this.syncStatus = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CustomersCompanion.insert({
    required String id,
    required String code,
    required String shopName,
    required String contactPerson,
    required String phone,
    required String address,
    this.category = const Value.absent(),
    this.groupName = const Value.absent(),
    this.latitude = const Value.absent(),
    this.longitude = const Value.absent(),
    this.isActive = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.ntnGst = const Value.absent(),
    this.orgId = const Value.absent(),
    this.syncStatus = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        code = Value(code),
        shopName = Value(shopName),
        contactPerson = Value(contactPerson),
        phone = Value(phone),
        address = Value(address);
  static Insertable<CustomersData> custom({
    Expression<String>? id,
    Expression<String>? code,
    Expression<String>? shopName,
    Expression<String>? contactPerson,
    Expression<String>? phone,
    Expression<String>? address,
    Expression<String>? category,
    Expression<String>? groupName,
    Expression<double>? latitude,
    Expression<double>? longitude,
    Expression<bool>? isActive,
    Expression<DateTime>? updatedAt,
    Expression<String>? ntnGst,
    Expression<String>? orgId,
    Expression<String>? syncStatus,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (code != null) 'code': code,
      if (shopName != null) 'shop_name': shopName,
      if (contactPerson != null) 'contact_person': contactPerson,
      if (phone != null) 'phone': phone,
      if (address != null) 'address': address,
      if (category != null) 'category': category,
      if (groupName != null) 'group_name': groupName,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (isActive != null) 'is_active': isActive,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (ntnGst != null) 'ntn_gst': ntnGst,
      if (orgId != null) 'org_id': orgId,
      if (syncStatus != null) 'sync_status': syncStatus,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CustomersCompanion copyWith(
      {Value<String>? id,
      Value<String>? code,
      Value<String>? shopName,
      Value<String>? contactPerson,
      Value<String>? phone,
      Value<String>? address,
      Value<String?>? category,
      Value<String?>? groupName,
      Value<double?>? latitude,
      Value<double?>? longitude,
      Value<bool>? isActive,
      Value<DateTime?>? updatedAt,
      Value<String?>? ntnGst,
      Value<String?>? orgId,
      Value<String>? syncStatus,
      Value<int>? rowid}) {
    return CustomersCompanion(
      id: id ?? this.id,
      code: code ?? this.code,
      shopName: shopName ?? this.shopName,
      contactPerson: contactPerson ?? this.contactPerson,
      phone: phone ?? this.phone,
      address: address ?? this.address,
      category: category ?? this.category,
      groupName: groupName ?? this.groupName,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      isActive: isActive ?? this.isActive,
      updatedAt: updatedAt ?? this.updatedAt,
      ntnGst: ntnGst ?? this.ntnGst,
      orgId: orgId ?? this.orgId,
      syncStatus: syncStatus ?? this.syncStatus,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (code.present) {
      map['code'] = Variable<String>(code.value);
    }
    if (shopName.present) {
      map['shop_name'] = Variable<String>(shopName.value);
    }
    if (contactPerson.present) {
      map['contact_person'] = Variable<String>(contactPerson.value);
    }
    if (phone.present) {
      map['phone'] = Variable<String>(phone.value);
    }
    if (address.present) {
      map['address'] = Variable<String>(address.value);
    }
    if (category.present) {
      map['category'] = Variable<String>(category.value);
    }
    if (groupName.present) {
      map['group_name'] = Variable<String>(groupName.value);
    }
    if (latitude.present) {
      map['latitude'] = Variable<double>(latitude.value);
    }
    if (longitude.present) {
      map['longitude'] = Variable<double>(longitude.value);
    }
    if (isActive.present) {
      map['is_active'] = Variable<bool>(isActive.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (ntnGst.present) {
      map['ntn_gst'] = Variable<String>(ntnGst.value);
    }
    if (orgId.present) {
      map['org_id'] = Variable<String>(orgId.value);
    }
    if (syncStatus.present) {
      map['sync_status'] = Variable<String>(syncStatus.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CustomersCompanion(')
          ..write('id: $id, ')
          ..write('code: $code, ')
          ..write('shopName: $shopName, ')
          ..write('contactPerson: $contactPerson, ')
          ..write('phone: $phone, ')
          ..write('address: $address, ')
          ..write('category: $category, ')
          ..write('groupName: $groupName, ')
          ..write('latitude: $latitude, ')
          ..write('longitude: $longitude, ')
          ..write('isActive: $isActive, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('ntnGst: $ntnGst, ')
          ..write('orgId: $orgId, ')
          ..write('syncStatus: $syncStatus, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SalesRoutesTableTable extends SalesRoutesTable
    with TableInfo<$SalesRoutesTableTable, SalesRoutesData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SalesRoutesTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
      'kind', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _isActiveMeta =
      const VerificationMeta('isActive');
  @override
  late final GeneratedColumn<bool> isActive = GeneratedColumn<bool>(
      'is_active', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_active" IN (0, 1))'),
      defaultValue: const Constant(true));
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _orgIdMeta = const VerificationMeta('orgId');
  @override
  late final GeneratedColumn<String> orgId = GeneratedColumn<String>(
      'org_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns =>
      [id, name, kind, isActive, createdAt, updatedAt, orgId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sales_routes';
  @override
  VerificationContext validateIntegrity(Insertable<SalesRoutesData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
          _kindMeta, kind.isAcceptableOrUnknown(data['kind']!, _kindMeta));
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('is_active')) {
      context.handle(_isActiveMeta,
          isActive.isAcceptableOrUnknown(data['is_active']!, _isActiveMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    if (data.containsKey('org_id')) {
      context.handle(
          _orgIdMeta, orgId.isAcceptableOrUnknown(data['org_id']!, _orgIdMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SalesRoutesData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SalesRoutesData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      kind: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}kind'])!,
      isActive: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_active'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at']),
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at']),
      orgId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}org_id']),
    );
  }

  @override
  $SalesRoutesTableTable createAlias(String alias) {
    return $SalesRoutesTableTable(attachedDatabase, alias);
  }
}

class SalesRoutesData extends DataClass implements Insertable<SalesRoutesData> {
  final String id;
  final String name;
  final String kind;
  final bool isActive;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? orgId;
  const SalesRoutesData(
      {required this.id,
      required this.name,
      required this.kind,
      required this.isActive,
      this.createdAt,
      this.updatedAt,
      this.orgId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['kind'] = Variable<String>(kind);
    map['is_active'] = Variable<bool>(isActive);
    if (!nullToAbsent || createdAt != null) {
      map['created_at'] = Variable<DateTime>(createdAt);
    }
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    if (!nullToAbsent || orgId != null) {
      map['org_id'] = Variable<String>(orgId);
    }
    return map;
  }

  SalesRoutesTableCompanion toCompanion(bool nullToAbsent) {
    return SalesRoutesTableCompanion(
      id: Value(id),
      name: Value(name),
      kind: Value(kind),
      isActive: Value(isActive),
      createdAt: createdAt == null && nullToAbsent
          ? const Value.absent()
          : Value(createdAt),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
      orgId:
          orgId == null && nullToAbsent ? const Value.absent() : Value(orgId),
    );
  }

  factory SalesRoutesData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SalesRoutesData(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      kind: serializer.fromJson<String>(json['kind']),
      isActive: serializer.fromJson<bool>(json['isActive']),
      createdAt: serializer.fromJson<DateTime?>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
      orgId: serializer.fromJson<String?>(json['orgId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'kind': serializer.toJson<String>(kind),
      'isActive': serializer.toJson<bool>(isActive),
      'createdAt': serializer.toJson<DateTime?>(createdAt),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
      'orgId': serializer.toJson<String?>(orgId),
    };
  }

  SalesRoutesData copyWith(
          {String? id,
          String? name,
          String? kind,
          bool? isActive,
          Value<DateTime?> createdAt = const Value.absent(),
          Value<DateTime?> updatedAt = const Value.absent(),
          Value<String?> orgId = const Value.absent()}) =>
      SalesRoutesData(
        id: id ?? this.id,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        isActive: isActive ?? this.isActive,
        createdAt: createdAt.present ? createdAt.value : this.createdAt,
        updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
        orgId: orgId.present ? orgId.value : this.orgId,
      );
  SalesRoutesData copyWithCompanion(SalesRoutesTableCompanion data) {
    return SalesRoutesData(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      kind: data.kind.present ? data.kind.value : this.kind,
      isActive: data.isActive.present ? data.isActive.value : this.isActive,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      orgId: data.orgId.present ? data.orgId.value : this.orgId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SalesRoutesData(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('kind: $kind, ')
          ..write('isActive: $isActive, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('orgId: $orgId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, name, kind, isActive, createdAt, updatedAt, orgId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SalesRoutesData &&
          other.id == this.id &&
          other.name == this.name &&
          other.kind == this.kind &&
          other.isActive == this.isActive &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.orgId == this.orgId);
}

class SalesRoutesTableCompanion extends UpdateCompanion<SalesRoutesData> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> kind;
  final Value<bool> isActive;
  final Value<DateTime?> createdAt;
  final Value<DateTime?> updatedAt;
  final Value<String?> orgId;
  final Value<int> rowid;
  const SalesRoutesTableCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.kind = const Value.absent(),
    this.isActive = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.orgId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SalesRoutesTableCompanion.insert({
    required String id,
    required String name,
    required String kind,
    this.isActive = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.orgId = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        name = Value(name),
        kind = Value(kind);
  static Insertable<SalesRoutesData> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? kind,
    Expression<bool>? isActive,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<String>? orgId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (kind != null) 'kind': kind,
      if (isActive != null) 'is_active': isActive,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (orgId != null) 'org_id': orgId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SalesRoutesTableCompanion copyWith(
      {Value<String>? id,
      Value<String>? name,
      Value<String>? kind,
      Value<bool>? isActive,
      Value<DateTime?>? createdAt,
      Value<DateTime?>? updatedAt,
      Value<String?>? orgId,
      Value<int>? rowid}) {
    return SalesRoutesTableCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      orgId: orgId ?? this.orgId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (isActive.present) {
      map['is_active'] = Variable<bool>(isActive.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (orgId.present) {
      map['org_id'] = Variable<String>(orgId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SalesRoutesTableCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('kind: $kind, ')
          ..write('isActive: $isActive, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('orgId: $orgId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RouteStopsTable extends RouteStops
    with TableInfo<$RouteStopsTable, RouteStopsData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RouteStopsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _routeIdMeta =
      const VerificationMeta('routeId');
  @override
  late final GeneratedColumn<String> routeId = GeneratedColumn<String>(
      'route_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES sales_routes (id)'));
  static const VerificationMeta _customerIdMeta =
      const VerificationMeta('customerId');
  @override
  late final GeneratedColumn<String> customerId = GeneratedColumn<String>(
      'customer_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES customers (id)'));
  static const VerificationMeta _positionMeta =
      const VerificationMeta('position');
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
      'position', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [routeId, customerId, position];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'route_stops';
  @override
  VerificationContext validateIntegrity(Insertable<RouteStopsData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('route_id')) {
      context.handle(_routeIdMeta,
          routeId.isAcceptableOrUnknown(data['route_id']!, _routeIdMeta));
    } else if (isInserting) {
      context.missing(_routeIdMeta);
    }
    if (data.containsKey('customer_id')) {
      context.handle(
          _customerIdMeta,
          customerId.isAcceptableOrUnknown(
              data['customer_id']!, _customerIdMeta));
    } else if (isInserting) {
      context.missing(_customerIdMeta);
    }
    if (data.containsKey('position')) {
      context.handle(_positionMeta,
          position.isAcceptableOrUnknown(data['position']!, _positionMeta));
    } else if (isInserting) {
      context.missing(_positionMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {routeId, customerId};
  @override
  RouteStopsData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RouteStopsData(
      routeId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}route_id'])!,
      customerId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}customer_id'])!,
      position: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}position'])!,
    );
  }

  @override
  $RouteStopsTable createAlias(String alias) {
    return $RouteStopsTable(attachedDatabase, alias);
  }
}

class RouteStopsData extends DataClass implements Insertable<RouteStopsData> {
  final String routeId;
  final String customerId;
  final int position;
  const RouteStopsData(
      {required this.routeId,
      required this.customerId,
      required this.position});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['route_id'] = Variable<String>(routeId);
    map['customer_id'] = Variable<String>(customerId);
    map['position'] = Variable<int>(position);
    return map;
  }

  RouteStopsCompanion toCompanion(bool nullToAbsent) {
    return RouteStopsCompanion(
      routeId: Value(routeId),
      customerId: Value(customerId),
      position: Value(position),
    );
  }

  factory RouteStopsData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RouteStopsData(
      routeId: serializer.fromJson<String>(json['routeId']),
      customerId: serializer.fromJson<String>(json['customerId']),
      position: serializer.fromJson<int>(json['position']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'routeId': serializer.toJson<String>(routeId),
      'customerId': serializer.toJson<String>(customerId),
      'position': serializer.toJson<int>(position),
    };
  }

  RouteStopsData copyWith(
          {String? routeId, String? customerId, int? position}) =>
      RouteStopsData(
        routeId: routeId ?? this.routeId,
        customerId: customerId ?? this.customerId,
        position: position ?? this.position,
      );
  RouteStopsData copyWithCompanion(RouteStopsCompanion data) {
    return RouteStopsData(
      routeId: data.routeId.present ? data.routeId.value : this.routeId,
      customerId:
          data.customerId.present ? data.customerId.value : this.customerId,
      position: data.position.present ? data.position.value : this.position,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RouteStopsData(')
          ..write('routeId: $routeId, ')
          ..write('customerId: $customerId, ')
          ..write('position: $position')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(routeId, customerId, position);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RouteStopsData &&
          other.routeId == this.routeId &&
          other.customerId == this.customerId &&
          other.position == this.position);
}

class RouteStopsCompanion extends UpdateCompanion<RouteStopsData> {
  final Value<String> routeId;
  final Value<String> customerId;
  final Value<int> position;
  final Value<int> rowid;
  const RouteStopsCompanion({
    this.routeId = const Value.absent(),
    this.customerId = const Value.absent(),
    this.position = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RouteStopsCompanion.insert({
    required String routeId,
    required String customerId,
    required int position,
    this.rowid = const Value.absent(),
  })  : routeId = Value(routeId),
        customerId = Value(customerId),
        position = Value(position);
  static Insertable<RouteStopsData> custom({
    Expression<String>? routeId,
    Expression<String>? customerId,
    Expression<int>? position,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (routeId != null) 'route_id': routeId,
      if (customerId != null) 'customer_id': customerId,
      if (position != null) 'position': position,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RouteStopsCompanion copyWith(
      {Value<String>? routeId,
      Value<String>? customerId,
      Value<int>? position,
      Value<int>? rowid}) {
    return RouteStopsCompanion(
      routeId: routeId ?? this.routeId,
      customerId: customerId ?? this.customerId,
      position: position ?? this.position,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (routeId.present) {
      map['route_id'] = Variable<String>(routeId.value);
    }
    if (customerId.present) {
      map['customer_id'] = Variable<String>(customerId.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RouteStopsCompanion(')
          ..write('routeId: $routeId, ')
          ..write('customerId: $customerId, ')
          ..write('position: $position, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TripsTable extends Trips with TableInfo<$TripsTable, TripsData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TripsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _routeIdMeta =
      const VerificationMeta('routeId');
  @override
  late final GeneratedColumn<String> routeId = GeneratedColumn<String>(
      'route_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _routeNameMeta =
      const VerificationMeta('routeName');
  @override
  late final GeneratedColumn<String> routeName = GeneratedColumn<String>(
      'route_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _routeKindMeta =
      const VerificationMeta('routeKind');
  @override
  late final GeneratedColumn<String> routeKind = GeneratedColumn<String>(
      'route_kind', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _startedAtMeta =
      const VerificationMeta('startedAt');
  @override
  late final GeneratedColumn<DateTime> startedAt = GeneratedColumn<DateTime>(
      'started_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _endedAtMeta =
      const VerificationMeta('endedAt');
  @override
  late final GeneratedColumn<DateTime> endedAt = GeneratedColumn<DateTime>(
      'ended_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _closeReasonMeta =
      const VerificationMeta('closeReason');
  @override
  late final GeneratedColumn<String> closeReason = GeneratedColumn<String>(
      'close_reason', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _startLatMeta =
      const VerificationMeta('startLat');
  @override
  late final GeneratedColumn<double> startLat = GeneratedColumn<double>(
      'start_lat', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _startLngMeta =
      const VerificationMeta('startLng');
  @override
  late final GeneratedColumn<double> startLng = GeneratedColumn<double>(
      'start_lng', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _endLatMeta = const VerificationMeta('endLat');
  @override
  late final GeneratedColumn<double> endLat = GeneratedColumn<double>(
      'end_lat', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _endLngMeta = const VerificationMeta('endLng');
  @override
  late final GeneratedColumn<double> endLng = GeneratedColumn<double>(
      'end_lng', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
      'user_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _userNameMeta =
      const VerificationMeta('userName');
  @override
  late final GeneratedColumn<String> userName = GeneratedColumn<String>(
      'user_name', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _userRoleMeta =
      const VerificationMeta('userRole');
  @override
  late final GeneratedColumn<String> userRole = GeneratedColumn<String>(
      'user_role', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _orgIdMeta = const VerificationMeta('orgId');
  @override
  late final GeneratedColumn<String> orgId = GeneratedColumn<String>(
      'org_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        routeId,
        routeName,
        routeKind,
        startedAt,
        endedAt,
        closeReason,
        startLat,
        startLng,
        endLat,
        endLng,
        userId,
        userName,
        userRole,
        orgId
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'trips';
  @override
  VerificationContext validateIntegrity(Insertable<TripsData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('route_id')) {
      context.handle(_routeIdMeta,
          routeId.isAcceptableOrUnknown(data['route_id']!, _routeIdMeta));
    } else if (isInserting) {
      context.missing(_routeIdMeta);
    }
    if (data.containsKey('route_name')) {
      context.handle(_routeNameMeta,
          routeName.isAcceptableOrUnknown(data['route_name']!, _routeNameMeta));
    } else if (isInserting) {
      context.missing(_routeNameMeta);
    }
    if (data.containsKey('route_kind')) {
      context.handle(_routeKindMeta,
          routeKind.isAcceptableOrUnknown(data['route_kind']!, _routeKindMeta));
    } else if (isInserting) {
      context.missing(_routeKindMeta);
    }
    if (data.containsKey('started_at')) {
      context.handle(_startedAtMeta,
          startedAt.isAcceptableOrUnknown(data['started_at']!, _startedAtMeta));
    } else if (isInserting) {
      context.missing(_startedAtMeta);
    }
    if (data.containsKey('ended_at')) {
      context.handle(_endedAtMeta,
          endedAt.isAcceptableOrUnknown(data['ended_at']!, _endedAtMeta));
    }
    if (data.containsKey('close_reason')) {
      context.handle(
          _closeReasonMeta,
          closeReason.isAcceptableOrUnknown(
              data['close_reason']!, _closeReasonMeta));
    }
    if (data.containsKey('start_lat')) {
      context.handle(_startLatMeta,
          startLat.isAcceptableOrUnknown(data['start_lat']!, _startLatMeta));
    }
    if (data.containsKey('start_lng')) {
      context.handle(_startLngMeta,
          startLng.isAcceptableOrUnknown(data['start_lng']!, _startLngMeta));
    }
    if (data.containsKey('end_lat')) {
      context.handle(_endLatMeta,
          endLat.isAcceptableOrUnknown(data['end_lat']!, _endLatMeta));
    }
    if (data.containsKey('end_lng')) {
      context.handle(_endLngMeta,
          endLng.isAcceptableOrUnknown(data['end_lng']!, _endLngMeta));
    }
    if (data.containsKey('user_id')) {
      context.handle(_userIdMeta,
          userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta));
    }
    if (data.containsKey('user_name')) {
      context.handle(_userNameMeta,
          userName.isAcceptableOrUnknown(data['user_name']!, _userNameMeta));
    }
    if (data.containsKey('user_role')) {
      context.handle(_userRoleMeta,
          userRole.isAcceptableOrUnknown(data['user_role']!, _userRoleMeta));
    }
    if (data.containsKey('org_id')) {
      context.handle(
          _orgIdMeta, orgId.isAcceptableOrUnknown(data['org_id']!, _orgIdMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TripsData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TripsData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      routeId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}route_id'])!,
      routeName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}route_name'])!,
      routeKind: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}route_kind'])!,
      startedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}started_at'])!,
      endedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}ended_at']),
      closeReason: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}close_reason']),
      startLat: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}start_lat']),
      startLng: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}start_lng']),
      endLat: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}end_lat']),
      endLng: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}end_lng']),
      userId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}user_id'])!,
      userName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}user_name'])!,
      userRole: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}user_role'])!,
      orgId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}org_id']),
    );
  }

  @override
  $TripsTable createAlias(String alias) {
    return $TripsTable(attachedDatabase, alias);
  }
}

class TripsData extends DataClass implements Insertable<TripsData> {
  final String id;
  final String routeId;
  final String routeName;
  final String routeKind;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String? closeReason;
  final double? startLat;
  final double? startLng;
  final double? endLat;
  final double? endLng;
  final String userId;
  final String userName;
  final String userRole;
  final String? orgId;
  const TripsData(
      {required this.id,
      required this.routeId,
      required this.routeName,
      required this.routeKind,
      required this.startedAt,
      this.endedAt,
      this.closeReason,
      this.startLat,
      this.startLng,
      this.endLat,
      this.endLng,
      required this.userId,
      required this.userName,
      required this.userRole,
      this.orgId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['route_id'] = Variable<String>(routeId);
    map['route_name'] = Variable<String>(routeName);
    map['route_kind'] = Variable<String>(routeKind);
    map['started_at'] = Variable<DateTime>(startedAt);
    if (!nullToAbsent || endedAt != null) {
      map['ended_at'] = Variable<DateTime>(endedAt);
    }
    if (!nullToAbsent || closeReason != null) {
      map['close_reason'] = Variable<String>(closeReason);
    }
    if (!nullToAbsent || startLat != null) {
      map['start_lat'] = Variable<double>(startLat);
    }
    if (!nullToAbsent || startLng != null) {
      map['start_lng'] = Variable<double>(startLng);
    }
    if (!nullToAbsent || endLat != null) {
      map['end_lat'] = Variable<double>(endLat);
    }
    if (!nullToAbsent || endLng != null) {
      map['end_lng'] = Variable<double>(endLng);
    }
    map['user_id'] = Variable<String>(userId);
    map['user_name'] = Variable<String>(userName);
    map['user_role'] = Variable<String>(userRole);
    if (!nullToAbsent || orgId != null) {
      map['org_id'] = Variable<String>(orgId);
    }
    return map;
  }

  TripsCompanion toCompanion(bool nullToAbsent) {
    return TripsCompanion(
      id: Value(id),
      routeId: Value(routeId),
      routeName: Value(routeName),
      routeKind: Value(routeKind),
      startedAt: Value(startedAt),
      endedAt: endedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(endedAt),
      closeReason: closeReason == null && nullToAbsent
          ? const Value.absent()
          : Value(closeReason),
      startLat: startLat == null && nullToAbsent
          ? const Value.absent()
          : Value(startLat),
      startLng: startLng == null && nullToAbsent
          ? const Value.absent()
          : Value(startLng),
      endLat:
          endLat == null && nullToAbsent ? const Value.absent() : Value(endLat),
      endLng:
          endLng == null && nullToAbsent ? const Value.absent() : Value(endLng),
      userId: Value(userId),
      userName: Value(userName),
      userRole: Value(userRole),
      orgId:
          orgId == null && nullToAbsent ? const Value.absent() : Value(orgId),
    );
  }

  factory TripsData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TripsData(
      id: serializer.fromJson<String>(json['id']),
      routeId: serializer.fromJson<String>(json['routeId']),
      routeName: serializer.fromJson<String>(json['routeName']),
      routeKind: serializer.fromJson<String>(json['routeKind']),
      startedAt: serializer.fromJson<DateTime>(json['startedAt']),
      endedAt: serializer.fromJson<DateTime?>(json['endedAt']),
      closeReason: serializer.fromJson<String?>(json['closeReason']),
      startLat: serializer.fromJson<double?>(json['startLat']),
      startLng: serializer.fromJson<double?>(json['startLng']),
      endLat: serializer.fromJson<double?>(json['endLat']),
      endLng: serializer.fromJson<double?>(json['endLng']),
      userId: serializer.fromJson<String>(json['userId']),
      userName: serializer.fromJson<String>(json['userName']),
      userRole: serializer.fromJson<String>(json['userRole']),
      orgId: serializer.fromJson<String?>(json['orgId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'routeId': serializer.toJson<String>(routeId),
      'routeName': serializer.toJson<String>(routeName),
      'routeKind': serializer.toJson<String>(routeKind),
      'startedAt': serializer.toJson<DateTime>(startedAt),
      'endedAt': serializer.toJson<DateTime?>(endedAt),
      'closeReason': serializer.toJson<String?>(closeReason),
      'startLat': serializer.toJson<double?>(startLat),
      'startLng': serializer.toJson<double?>(startLng),
      'endLat': serializer.toJson<double?>(endLat),
      'endLng': serializer.toJson<double?>(endLng),
      'userId': serializer.toJson<String>(userId),
      'userName': serializer.toJson<String>(userName),
      'userRole': serializer.toJson<String>(userRole),
      'orgId': serializer.toJson<String?>(orgId),
    };
  }

  TripsData copyWith(
          {String? id,
          String? routeId,
          String? routeName,
          String? routeKind,
          DateTime? startedAt,
          Value<DateTime?> endedAt = const Value.absent(),
          Value<String?> closeReason = const Value.absent(),
          Value<double?> startLat = const Value.absent(),
          Value<double?> startLng = const Value.absent(),
          Value<double?> endLat = const Value.absent(),
          Value<double?> endLng = const Value.absent(),
          String? userId,
          String? userName,
          String? userRole,
          Value<String?> orgId = const Value.absent()}) =>
      TripsData(
        id: id ?? this.id,
        routeId: routeId ?? this.routeId,
        routeName: routeName ?? this.routeName,
        routeKind: routeKind ?? this.routeKind,
        startedAt: startedAt ?? this.startedAt,
        endedAt: endedAt.present ? endedAt.value : this.endedAt,
        closeReason: closeReason.present ? closeReason.value : this.closeReason,
        startLat: startLat.present ? startLat.value : this.startLat,
        startLng: startLng.present ? startLng.value : this.startLng,
        endLat: endLat.present ? endLat.value : this.endLat,
        endLng: endLng.present ? endLng.value : this.endLng,
        userId: userId ?? this.userId,
        userName: userName ?? this.userName,
        userRole: userRole ?? this.userRole,
        orgId: orgId.present ? orgId.value : this.orgId,
      );
  TripsData copyWithCompanion(TripsCompanion data) {
    return TripsData(
      id: data.id.present ? data.id.value : this.id,
      routeId: data.routeId.present ? data.routeId.value : this.routeId,
      routeName: data.routeName.present ? data.routeName.value : this.routeName,
      routeKind: data.routeKind.present ? data.routeKind.value : this.routeKind,
      startedAt: data.startedAt.present ? data.startedAt.value : this.startedAt,
      endedAt: data.endedAt.present ? data.endedAt.value : this.endedAt,
      closeReason:
          data.closeReason.present ? data.closeReason.value : this.closeReason,
      startLat: data.startLat.present ? data.startLat.value : this.startLat,
      startLng: data.startLng.present ? data.startLng.value : this.startLng,
      endLat: data.endLat.present ? data.endLat.value : this.endLat,
      endLng: data.endLng.present ? data.endLng.value : this.endLng,
      userId: data.userId.present ? data.userId.value : this.userId,
      userName: data.userName.present ? data.userName.value : this.userName,
      userRole: data.userRole.present ? data.userRole.value : this.userRole,
      orgId: data.orgId.present ? data.orgId.value : this.orgId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TripsData(')
          ..write('id: $id, ')
          ..write('routeId: $routeId, ')
          ..write('routeName: $routeName, ')
          ..write('routeKind: $routeKind, ')
          ..write('startedAt: $startedAt, ')
          ..write('endedAt: $endedAt, ')
          ..write('closeReason: $closeReason, ')
          ..write('startLat: $startLat, ')
          ..write('startLng: $startLng, ')
          ..write('endLat: $endLat, ')
          ..write('endLng: $endLng, ')
          ..write('userId: $userId, ')
          ..write('userName: $userName, ')
          ..write('userRole: $userRole, ')
          ..write('orgId: $orgId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      routeId,
      routeName,
      routeKind,
      startedAt,
      endedAt,
      closeReason,
      startLat,
      startLng,
      endLat,
      endLng,
      userId,
      userName,
      userRole,
      orgId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TripsData &&
          other.id == this.id &&
          other.routeId == this.routeId &&
          other.routeName == this.routeName &&
          other.routeKind == this.routeKind &&
          other.startedAt == this.startedAt &&
          other.endedAt == this.endedAt &&
          other.closeReason == this.closeReason &&
          other.startLat == this.startLat &&
          other.startLng == this.startLng &&
          other.endLat == this.endLat &&
          other.endLng == this.endLng &&
          other.userId == this.userId &&
          other.userName == this.userName &&
          other.userRole == this.userRole &&
          other.orgId == this.orgId);
}

class TripsCompanion extends UpdateCompanion<TripsData> {
  final Value<String> id;
  final Value<String> routeId;
  final Value<String> routeName;
  final Value<String> routeKind;
  final Value<DateTime> startedAt;
  final Value<DateTime?> endedAt;
  final Value<String?> closeReason;
  final Value<double?> startLat;
  final Value<double?> startLng;
  final Value<double?> endLat;
  final Value<double?> endLng;
  final Value<String> userId;
  final Value<String> userName;
  final Value<String> userRole;
  final Value<String?> orgId;
  final Value<int> rowid;
  const TripsCompanion({
    this.id = const Value.absent(),
    this.routeId = const Value.absent(),
    this.routeName = const Value.absent(),
    this.routeKind = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.endedAt = const Value.absent(),
    this.closeReason = const Value.absent(),
    this.startLat = const Value.absent(),
    this.startLng = const Value.absent(),
    this.endLat = const Value.absent(),
    this.endLng = const Value.absent(),
    this.userId = const Value.absent(),
    this.userName = const Value.absent(),
    this.userRole = const Value.absent(),
    this.orgId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TripsCompanion.insert({
    required String id,
    required String routeId,
    required String routeName,
    required String routeKind,
    required DateTime startedAt,
    this.endedAt = const Value.absent(),
    this.closeReason = const Value.absent(),
    this.startLat = const Value.absent(),
    this.startLng = const Value.absent(),
    this.endLat = const Value.absent(),
    this.endLng = const Value.absent(),
    this.userId = const Value.absent(),
    this.userName = const Value.absent(),
    this.userRole = const Value.absent(),
    this.orgId = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        routeId = Value(routeId),
        routeName = Value(routeName),
        routeKind = Value(routeKind),
        startedAt = Value(startedAt);
  static Insertable<TripsData> custom({
    Expression<String>? id,
    Expression<String>? routeId,
    Expression<String>? routeName,
    Expression<String>? routeKind,
    Expression<DateTime>? startedAt,
    Expression<DateTime>? endedAt,
    Expression<String>? closeReason,
    Expression<double>? startLat,
    Expression<double>? startLng,
    Expression<double>? endLat,
    Expression<double>? endLng,
    Expression<String>? userId,
    Expression<String>? userName,
    Expression<String>? userRole,
    Expression<String>? orgId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (routeId != null) 'route_id': routeId,
      if (routeName != null) 'route_name': routeName,
      if (routeKind != null) 'route_kind': routeKind,
      if (startedAt != null) 'started_at': startedAt,
      if (endedAt != null) 'ended_at': endedAt,
      if (closeReason != null) 'close_reason': closeReason,
      if (startLat != null) 'start_lat': startLat,
      if (startLng != null) 'start_lng': startLng,
      if (endLat != null) 'end_lat': endLat,
      if (endLng != null) 'end_lng': endLng,
      if (userId != null) 'user_id': userId,
      if (userName != null) 'user_name': userName,
      if (userRole != null) 'user_role': userRole,
      if (orgId != null) 'org_id': orgId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TripsCompanion copyWith(
      {Value<String>? id,
      Value<String>? routeId,
      Value<String>? routeName,
      Value<String>? routeKind,
      Value<DateTime>? startedAt,
      Value<DateTime?>? endedAt,
      Value<String?>? closeReason,
      Value<double?>? startLat,
      Value<double?>? startLng,
      Value<double?>? endLat,
      Value<double?>? endLng,
      Value<String>? userId,
      Value<String>? userName,
      Value<String>? userRole,
      Value<String?>? orgId,
      Value<int>? rowid}) {
    return TripsCompanion(
      id: id ?? this.id,
      routeId: routeId ?? this.routeId,
      routeName: routeName ?? this.routeName,
      routeKind: routeKind ?? this.routeKind,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      closeReason: closeReason ?? this.closeReason,
      startLat: startLat ?? this.startLat,
      startLng: startLng ?? this.startLng,
      endLat: endLat ?? this.endLat,
      endLng: endLng ?? this.endLng,
      userId: userId ?? this.userId,
      userName: userName ?? this.userName,
      userRole: userRole ?? this.userRole,
      orgId: orgId ?? this.orgId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (routeId.present) {
      map['route_id'] = Variable<String>(routeId.value);
    }
    if (routeName.present) {
      map['route_name'] = Variable<String>(routeName.value);
    }
    if (routeKind.present) {
      map['route_kind'] = Variable<String>(routeKind.value);
    }
    if (startedAt.present) {
      map['started_at'] = Variable<DateTime>(startedAt.value);
    }
    if (endedAt.present) {
      map['ended_at'] = Variable<DateTime>(endedAt.value);
    }
    if (closeReason.present) {
      map['close_reason'] = Variable<String>(closeReason.value);
    }
    if (startLat.present) {
      map['start_lat'] = Variable<double>(startLat.value);
    }
    if (startLng.present) {
      map['start_lng'] = Variable<double>(startLng.value);
    }
    if (endLat.present) {
      map['end_lat'] = Variable<double>(endLat.value);
    }
    if (endLng.present) {
      map['end_lng'] = Variable<double>(endLng.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (userName.present) {
      map['user_name'] = Variable<String>(userName.value);
    }
    if (userRole.present) {
      map['user_role'] = Variable<String>(userRole.value);
    }
    if (orgId.present) {
      map['org_id'] = Variable<String>(orgId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TripsCompanion(')
          ..write('id: $id, ')
          ..write('routeId: $routeId, ')
          ..write('routeName: $routeName, ')
          ..write('routeKind: $routeKind, ')
          ..write('startedAt: $startedAt, ')
          ..write('endedAt: $endedAt, ')
          ..write('closeReason: $closeReason, ')
          ..write('startLat: $startLat, ')
          ..write('startLng: $startLng, ')
          ..write('endLat: $endLat, ')
          ..write('endLng: $endLng, ')
          ..write('userId: $userId, ')
          ..write('userName: $userName, ')
          ..write('userRole: $userRole, ')
          ..write('orgId: $orgId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TripStopsTable extends TripStops
    with TableInfo<$TripStopsTable, TripStopsData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TripStopsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _tripIdMeta = const VerificationMeta('tripId');
  @override
  late final GeneratedColumn<String> tripId = GeneratedColumn<String>(
      'trip_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES trips (id)'));
  static const VerificationMeta _customerIdMeta =
      const VerificationMeta('customerId');
  @override
  late final GeneratedColumn<String> customerId = GeneratedColumn<String>(
      'customer_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES customers (id)'));
  static const VerificationMeta _positionMeta =
      const VerificationMeta('position');
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
      'position', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [tripId, customerId, position];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'trip_stops';
  @override
  VerificationContext validateIntegrity(Insertable<TripStopsData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('trip_id')) {
      context.handle(_tripIdMeta,
          tripId.isAcceptableOrUnknown(data['trip_id']!, _tripIdMeta));
    } else if (isInserting) {
      context.missing(_tripIdMeta);
    }
    if (data.containsKey('customer_id')) {
      context.handle(
          _customerIdMeta,
          customerId.isAcceptableOrUnknown(
              data['customer_id']!, _customerIdMeta));
    } else if (isInserting) {
      context.missing(_customerIdMeta);
    }
    if (data.containsKey('position')) {
      context.handle(_positionMeta,
          position.isAcceptableOrUnknown(data['position']!, _positionMeta));
    } else if (isInserting) {
      context.missing(_positionMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {tripId, customerId};
  @override
  TripStopsData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TripStopsData(
      tripId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}trip_id'])!,
      customerId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}customer_id'])!,
      position: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}position'])!,
    );
  }

  @override
  $TripStopsTable createAlias(String alias) {
    return $TripStopsTable(attachedDatabase, alias);
  }
}

class TripStopsData extends DataClass implements Insertable<TripStopsData> {
  final String tripId;
  final String customerId;
  final int position;
  const TripStopsData(
      {required this.tripId, required this.customerId, required this.position});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['trip_id'] = Variable<String>(tripId);
    map['customer_id'] = Variable<String>(customerId);
    map['position'] = Variable<int>(position);
    return map;
  }

  TripStopsCompanion toCompanion(bool nullToAbsent) {
    return TripStopsCompanion(
      tripId: Value(tripId),
      customerId: Value(customerId),
      position: Value(position),
    );
  }

  factory TripStopsData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TripStopsData(
      tripId: serializer.fromJson<String>(json['tripId']),
      customerId: serializer.fromJson<String>(json['customerId']),
      position: serializer.fromJson<int>(json['position']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'tripId': serializer.toJson<String>(tripId),
      'customerId': serializer.toJson<String>(customerId),
      'position': serializer.toJson<int>(position),
    };
  }

  TripStopsData copyWith({String? tripId, String? customerId, int? position}) =>
      TripStopsData(
        tripId: tripId ?? this.tripId,
        customerId: customerId ?? this.customerId,
        position: position ?? this.position,
      );
  TripStopsData copyWithCompanion(TripStopsCompanion data) {
    return TripStopsData(
      tripId: data.tripId.present ? data.tripId.value : this.tripId,
      customerId:
          data.customerId.present ? data.customerId.value : this.customerId,
      position: data.position.present ? data.position.value : this.position,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TripStopsData(')
          ..write('tripId: $tripId, ')
          ..write('customerId: $customerId, ')
          ..write('position: $position')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(tripId, customerId, position);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TripStopsData &&
          other.tripId == this.tripId &&
          other.customerId == this.customerId &&
          other.position == this.position);
}

class TripStopsCompanion extends UpdateCompanion<TripStopsData> {
  final Value<String> tripId;
  final Value<String> customerId;
  final Value<int> position;
  final Value<int> rowid;
  const TripStopsCompanion({
    this.tripId = const Value.absent(),
    this.customerId = const Value.absent(),
    this.position = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TripStopsCompanion.insert({
    required String tripId,
    required String customerId,
    required int position,
    this.rowid = const Value.absent(),
  })  : tripId = Value(tripId),
        customerId = Value(customerId),
        position = Value(position);
  static Insertable<TripStopsData> custom({
    Expression<String>? tripId,
    Expression<String>? customerId,
    Expression<int>? position,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (tripId != null) 'trip_id': tripId,
      if (customerId != null) 'customer_id': customerId,
      if (position != null) 'position': position,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TripStopsCompanion copyWith(
      {Value<String>? tripId,
      Value<String>? customerId,
      Value<int>? position,
      Value<int>? rowid}) {
    return TripStopsCompanion(
      tripId: tripId ?? this.tripId,
      customerId: customerId ?? this.customerId,
      position: position ?? this.position,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (tripId.present) {
      map['trip_id'] = Variable<String>(tripId.value);
    }
    if (customerId.present) {
      map['customer_id'] = Variable<String>(customerId.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TripStopsCompanion(')
          ..write('tripId: $tripId, ')
          ..write('customerId: $customerId, ')
          ..write('position: $position, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $VisitsTable extends Visits with TableInfo<$VisitsTable, VisitsData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $VisitsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _tripIdMeta = const VerificationMeta('tripId');
  @override
  late final GeneratedColumn<String> tripId = GeneratedColumn<String>(
      'trip_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES trips (id)'));
  static const VerificationMeta _customerIdMeta =
      const VerificationMeta('customerId');
  @override
  late final GeneratedColumn<String> customerId = GeneratedColumn<String>(
      'customer_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES customers (id)'));
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
      'status', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _timestampMeta =
      const VerificationMeta('timestamp');
  @override
  late final GeneratedColumn<DateTime> timestamp = GeneratedColumn<DateTime>(
      'timestamp', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _capturedLatMeta =
      const VerificationMeta('capturedLat');
  @override
  late final GeneratedColumn<double> capturedLat = GeneratedColumn<double>(
      'captured_lat', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _capturedLngMeta =
      const VerificationMeta('capturedLng');
  @override
  late final GeneratedColumn<double> capturedLng = GeneratedColumn<double>(
      'captured_lng', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _accuracyMetersMeta =
      const VerificationMeta('accuracyMeters');
  @override
  late final GeneratedColumn<double> accuracyMeters = GeneratedColumn<double>(
      'accuracy_meters', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _distanceMetersMeta =
      const VerificationMeta('distanceMeters');
  @override
  late final GeneratedColumn<double> distanceMeters = GeneratedColumn<double>(
      'distance_meters', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _amountMeta = const VerificationMeta('amount');
  @override
  late final GeneratedColumn<int> amount = GeneratedColumn<int>(
      'amount', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _receiptNumberMeta =
      const VerificationMeta('receiptNumber');
  @override
  late final GeneratedColumn<String> receiptNumber = GeneratedColumn<String>(
      'receipt_number', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
      'notes', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _skipReasonMeta =
      const VerificationMeta('skipReason');
  @override
  late final GeneratedColumn<String> skipReason = GeneratedColumn<String>(
      'skip_reason', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _photoPathsJsonMeta =
      const VerificationMeta('photoPathsJson');
  @override
  late final GeneratedColumn<String> photoPathsJson = GeneratedColumn<String>(
      'photo_paths_json', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('[]'));
  static const VerificationMeta _syncStatusMeta =
      const VerificationMeta('syncStatus');
  @override
  late final GeneratedColumn<String> syncStatus = GeneratedColumn<String>(
      'sync_status', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('pending'));
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
      'user_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _userNameMeta =
      const VerificationMeta('userName');
  @override
  late final GeneratedColumn<String> userName = GeneratedColumn<String>(
      'user_name', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _userRoleMeta =
      const VerificationMeta('userRole');
  @override
  late final GeneratedColumn<String> userRole = GeneratedColumn<String>(
      'user_role', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  @override
  List<GeneratedColumn> get $columns => [
        id,
        tripId,
        customerId,
        status,
        timestamp,
        capturedLat,
        capturedLng,
        accuracyMeters,
        distanceMeters,
        amount,
        receiptNumber,
        notes,
        skipReason,
        photoPathsJson,
        syncStatus,
        userId,
        userName,
        userRole
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'visits';
  @override
  VerificationContext validateIntegrity(Insertable<VisitsData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('trip_id')) {
      context.handle(_tripIdMeta,
          tripId.isAcceptableOrUnknown(data['trip_id']!, _tripIdMeta));
    } else if (isInserting) {
      context.missing(_tripIdMeta);
    }
    if (data.containsKey('customer_id')) {
      context.handle(
          _customerIdMeta,
          customerId.isAcceptableOrUnknown(
              data['customer_id']!, _customerIdMeta));
    } else if (isInserting) {
      context.missing(_customerIdMeta);
    }
    if (data.containsKey('status')) {
      context.handle(_statusMeta,
          status.isAcceptableOrUnknown(data['status']!, _statusMeta));
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('timestamp')) {
      context.handle(_timestampMeta,
          timestamp.isAcceptableOrUnknown(data['timestamp']!, _timestampMeta));
    } else if (isInserting) {
      context.missing(_timestampMeta);
    }
    if (data.containsKey('captured_lat')) {
      context.handle(
          _capturedLatMeta,
          capturedLat.isAcceptableOrUnknown(
              data['captured_lat']!, _capturedLatMeta));
    }
    if (data.containsKey('captured_lng')) {
      context.handle(
          _capturedLngMeta,
          capturedLng.isAcceptableOrUnknown(
              data['captured_lng']!, _capturedLngMeta));
    }
    if (data.containsKey('accuracy_meters')) {
      context.handle(
          _accuracyMetersMeta,
          accuracyMeters.isAcceptableOrUnknown(
              data['accuracy_meters']!, _accuracyMetersMeta));
    }
    if (data.containsKey('distance_meters')) {
      context.handle(
          _distanceMetersMeta,
          distanceMeters.isAcceptableOrUnknown(
              data['distance_meters']!, _distanceMetersMeta));
    }
    if (data.containsKey('amount')) {
      context.handle(_amountMeta,
          amount.isAcceptableOrUnknown(data['amount']!, _amountMeta));
    }
    if (data.containsKey('receipt_number')) {
      context.handle(
          _receiptNumberMeta,
          receiptNumber.isAcceptableOrUnknown(
              data['receipt_number']!, _receiptNumberMeta));
    }
    if (data.containsKey('notes')) {
      context.handle(
          _notesMeta, notes.isAcceptableOrUnknown(data['notes']!, _notesMeta));
    }
    if (data.containsKey('skip_reason')) {
      context.handle(
          _skipReasonMeta,
          skipReason.isAcceptableOrUnknown(
              data['skip_reason']!, _skipReasonMeta));
    }
    if (data.containsKey('photo_paths_json')) {
      context.handle(
          _photoPathsJsonMeta,
          photoPathsJson.isAcceptableOrUnknown(
              data['photo_paths_json']!, _photoPathsJsonMeta));
    }
    if (data.containsKey('sync_status')) {
      context.handle(
          _syncStatusMeta,
          syncStatus.isAcceptableOrUnknown(
              data['sync_status']!, _syncStatusMeta));
    }
    if (data.containsKey('user_id')) {
      context.handle(_userIdMeta,
          userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta));
    }
    if (data.containsKey('user_name')) {
      context.handle(_userNameMeta,
          userName.isAcceptableOrUnknown(data['user_name']!, _userNameMeta));
    }
    if (data.containsKey('user_role')) {
      context.handle(_userRoleMeta,
          userRole.isAcceptableOrUnknown(data['user_role']!, _userRoleMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  VisitsData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return VisitsData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      tripId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}trip_id'])!,
      customerId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}customer_id'])!,
      status: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}status'])!,
      timestamp: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}timestamp'])!,
      capturedLat: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}captured_lat']),
      capturedLng: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}captured_lng']),
      accuracyMeters: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}accuracy_meters']),
      distanceMeters: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}distance_meters']),
      amount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}amount'])!,
      receiptNumber: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}receipt_number']),
      notes: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}notes']),
      skipReason: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}skip_reason']),
      photoPathsJson: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}photo_paths_json'])!,
      syncStatus: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_status'])!,
      userId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}user_id'])!,
      userName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}user_name'])!,
      userRole: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}user_role'])!,
    );
  }

  @override
  $VisitsTable createAlias(String alias) {
    return $VisitsTable(attachedDatabase, alias);
  }
}

class VisitsData extends DataClass implements Insertable<VisitsData> {
  final String id;
  final String tripId;
  final String customerId;
  final String status;
  final DateTime timestamp;
  final double? capturedLat;
  final double? capturedLng;
  final double? accuracyMeters;
  final double? distanceMeters;
  final int amount;
  final String? receiptNumber;
  final String? notes;
  final String? skipReason;

  /// JSON-encoded list of photo paths (mock values in Slice 3a).
  final String photoPathsJson;

  /// Sync state (used by Slice 3b; present now to avoid schema migrations later).
  /// 'pending' (not yet synced) | 'synced' | 'rejected'
  final String syncStatus;
  final String userId;
  final String userName;
  final String userRole;
  const VisitsData(
      {required this.id,
      required this.tripId,
      required this.customerId,
      required this.status,
      required this.timestamp,
      this.capturedLat,
      this.capturedLng,
      this.accuracyMeters,
      this.distanceMeters,
      required this.amount,
      this.receiptNumber,
      this.notes,
      this.skipReason,
      required this.photoPathsJson,
      required this.syncStatus,
      required this.userId,
      required this.userName,
      required this.userRole});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['trip_id'] = Variable<String>(tripId);
    map['customer_id'] = Variable<String>(customerId);
    map['status'] = Variable<String>(status);
    map['timestamp'] = Variable<DateTime>(timestamp);
    if (!nullToAbsent || capturedLat != null) {
      map['captured_lat'] = Variable<double>(capturedLat);
    }
    if (!nullToAbsent || capturedLng != null) {
      map['captured_lng'] = Variable<double>(capturedLng);
    }
    if (!nullToAbsent || accuracyMeters != null) {
      map['accuracy_meters'] = Variable<double>(accuracyMeters);
    }
    if (!nullToAbsent || distanceMeters != null) {
      map['distance_meters'] = Variable<double>(distanceMeters);
    }
    map['amount'] = Variable<int>(amount);
    if (!nullToAbsent || receiptNumber != null) {
      map['receipt_number'] = Variable<String>(receiptNumber);
    }
    if (!nullToAbsent || notes != null) {
      map['notes'] = Variable<String>(notes);
    }
    if (!nullToAbsent || skipReason != null) {
      map['skip_reason'] = Variable<String>(skipReason);
    }
    map['photo_paths_json'] = Variable<String>(photoPathsJson);
    map['sync_status'] = Variable<String>(syncStatus);
    map['user_id'] = Variable<String>(userId);
    map['user_name'] = Variable<String>(userName);
    map['user_role'] = Variable<String>(userRole);
    return map;
  }

  VisitsCompanion toCompanion(bool nullToAbsent) {
    return VisitsCompanion(
      id: Value(id),
      tripId: Value(tripId),
      customerId: Value(customerId),
      status: Value(status),
      timestamp: Value(timestamp),
      capturedLat: capturedLat == null && nullToAbsent
          ? const Value.absent()
          : Value(capturedLat),
      capturedLng: capturedLng == null && nullToAbsent
          ? const Value.absent()
          : Value(capturedLng),
      accuracyMeters: accuracyMeters == null && nullToAbsent
          ? const Value.absent()
          : Value(accuracyMeters),
      distanceMeters: distanceMeters == null && nullToAbsent
          ? const Value.absent()
          : Value(distanceMeters),
      amount: Value(amount),
      receiptNumber: receiptNumber == null && nullToAbsent
          ? const Value.absent()
          : Value(receiptNumber),
      notes:
          notes == null && nullToAbsent ? const Value.absent() : Value(notes),
      skipReason: skipReason == null && nullToAbsent
          ? const Value.absent()
          : Value(skipReason),
      photoPathsJson: Value(photoPathsJson),
      syncStatus: Value(syncStatus),
      userId: Value(userId),
      userName: Value(userName),
      userRole: Value(userRole),
    );
  }

  factory VisitsData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return VisitsData(
      id: serializer.fromJson<String>(json['id']),
      tripId: serializer.fromJson<String>(json['tripId']),
      customerId: serializer.fromJson<String>(json['customerId']),
      status: serializer.fromJson<String>(json['status']),
      timestamp: serializer.fromJson<DateTime>(json['timestamp']),
      capturedLat: serializer.fromJson<double?>(json['capturedLat']),
      capturedLng: serializer.fromJson<double?>(json['capturedLng']),
      accuracyMeters: serializer.fromJson<double?>(json['accuracyMeters']),
      distanceMeters: serializer.fromJson<double?>(json['distanceMeters']),
      amount: serializer.fromJson<int>(json['amount']),
      receiptNumber: serializer.fromJson<String?>(json['receiptNumber']),
      notes: serializer.fromJson<String?>(json['notes']),
      skipReason: serializer.fromJson<String?>(json['skipReason']),
      photoPathsJson: serializer.fromJson<String>(json['photoPathsJson']),
      syncStatus: serializer.fromJson<String>(json['syncStatus']),
      userId: serializer.fromJson<String>(json['userId']),
      userName: serializer.fromJson<String>(json['userName']),
      userRole: serializer.fromJson<String>(json['userRole']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'tripId': serializer.toJson<String>(tripId),
      'customerId': serializer.toJson<String>(customerId),
      'status': serializer.toJson<String>(status),
      'timestamp': serializer.toJson<DateTime>(timestamp),
      'capturedLat': serializer.toJson<double?>(capturedLat),
      'capturedLng': serializer.toJson<double?>(capturedLng),
      'accuracyMeters': serializer.toJson<double?>(accuracyMeters),
      'distanceMeters': serializer.toJson<double?>(distanceMeters),
      'amount': serializer.toJson<int>(amount),
      'receiptNumber': serializer.toJson<String?>(receiptNumber),
      'notes': serializer.toJson<String?>(notes),
      'skipReason': serializer.toJson<String?>(skipReason),
      'photoPathsJson': serializer.toJson<String>(photoPathsJson),
      'syncStatus': serializer.toJson<String>(syncStatus),
      'userId': serializer.toJson<String>(userId),
      'userName': serializer.toJson<String>(userName),
      'userRole': serializer.toJson<String>(userRole),
    };
  }

  VisitsData copyWith(
          {String? id,
          String? tripId,
          String? customerId,
          String? status,
          DateTime? timestamp,
          Value<double?> capturedLat = const Value.absent(),
          Value<double?> capturedLng = const Value.absent(),
          Value<double?> accuracyMeters = const Value.absent(),
          Value<double?> distanceMeters = const Value.absent(),
          int? amount,
          Value<String?> receiptNumber = const Value.absent(),
          Value<String?> notes = const Value.absent(),
          Value<String?> skipReason = const Value.absent(),
          String? photoPathsJson,
          String? syncStatus,
          String? userId,
          String? userName,
          String? userRole}) =>
      VisitsData(
        id: id ?? this.id,
        tripId: tripId ?? this.tripId,
        customerId: customerId ?? this.customerId,
        status: status ?? this.status,
        timestamp: timestamp ?? this.timestamp,
        capturedLat: capturedLat.present ? capturedLat.value : this.capturedLat,
        capturedLng: capturedLng.present ? capturedLng.value : this.capturedLng,
        accuracyMeters:
            accuracyMeters.present ? accuracyMeters.value : this.accuracyMeters,
        distanceMeters:
            distanceMeters.present ? distanceMeters.value : this.distanceMeters,
        amount: amount ?? this.amount,
        receiptNumber:
            receiptNumber.present ? receiptNumber.value : this.receiptNumber,
        notes: notes.present ? notes.value : this.notes,
        skipReason: skipReason.present ? skipReason.value : this.skipReason,
        photoPathsJson: photoPathsJson ?? this.photoPathsJson,
        syncStatus: syncStatus ?? this.syncStatus,
        userId: userId ?? this.userId,
        userName: userName ?? this.userName,
        userRole: userRole ?? this.userRole,
      );
  VisitsData copyWithCompanion(VisitsCompanion data) {
    return VisitsData(
      id: data.id.present ? data.id.value : this.id,
      tripId: data.tripId.present ? data.tripId.value : this.tripId,
      customerId:
          data.customerId.present ? data.customerId.value : this.customerId,
      status: data.status.present ? data.status.value : this.status,
      timestamp: data.timestamp.present ? data.timestamp.value : this.timestamp,
      capturedLat:
          data.capturedLat.present ? data.capturedLat.value : this.capturedLat,
      capturedLng:
          data.capturedLng.present ? data.capturedLng.value : this.capturedLng,
      accuracyMeters: data.accuracyMeters.present
          ? data.accuracyMeters.value
          : this.accuracyMeters,
      distanceMeters: data.distanceMeters.present
          ? data.distanceMeters.value
          : this.distanceMeters,
      amount: data.amount.present ? data.amount.value : this.amount,
      receiptNumber: data.receiptNumber.present
          ? data.receiptNumber.value
          : this.receiptNumber,
      notes: data.notes.present ? data.notes.value : this.notes,
      skipReason:
          data.skipReason.present ? data.skipReason.value : this.skipReason,
      photoPathsJson: data.photoPathsJson.present
          ? data.photoPathsJson.value
          : this.photoPathsJson,
      syncStatus:
          data.syncStatus.present ? data.syncStatus.value : this.syncStatus,
      userId: data.userId.present ? data.userId.value : this.userId,
      userName: data.userName.present ? data.userName.value : this.userName,
      userRole: data.userRole.present ? data.userRole.value : this.userRole,
    );
  }

  @override
  String toString() {
    return (StringBuffer('VisitsData(')
          ..write('id: $id, ')
          ..write('tripId: $tripId, ')
          ..write('customerId: $customerId, ')
          ..write('status: $status, ')
          ..write('timestamp: $timestamp, ')
          ..write('capturedLat: $capturedLat, ')
          ..write('capturedLng: $capturedLng, ')
          ..write('accuracyMeters: $accuracyMeters, ')
          ..write('distanceMeters: $distanceMeters, ')
          ..write('amount: $amount, ')
          ..write('receiptNumber: $receiptNumber, ')
          ..write('notes: $notes, ')
          ..write('skipReason: $skipReason, ')
          ..write('photoPathsJson: $photoPathsJson, ')
          ..write('syncStatus: $syncStatus, ')
          ..write('userId: $userId, ')
          ..write('userName: $userName, ')
          ..write('userRole: $userRole')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      tripId,
      customerId,
      status,
      timestamp,
      capturedLat,
      capturedLng,
      accuracyMeters,
      distanceMeters,
      amount,
      receiptNumber,
      notes,
      skipReason,
      photoPathsJson,
      syncStatus,
      userId,
      userName,
      userRole);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VisitsData &&
          other.id == this.id &&
          other.tripId == this.tripId &&
          other.customerId == this.customerId &&
          other.status == this.status &&
          other.timestamp == this.timestamp &&
          other.capturedLat == this.capturedLat &&
          other.capturedLng == this.capturedLng &&
          other.accuracyMeters == this.accuracyMeters &&
          other.distanceMeters == this.distanceMeters &&
          other.amount == this.amount &&
          other.receiptNumber == this.receiptNumber &&
          other.notes == this.notes &&
          other.skipReason == this.skipReason &&
          other.photoPathsJson == this.photoPathsJson &&
          other.syncStatus == this.syncStatus &&
          other.userId == this.userId &&
          other.userName == this.userName &&
          other.userRole == this.userRole);
}

class VisitsCompanion extends UpdateCompanion<VisitsData> {
  final Value<String> id;
  final Value<String> tripId;
  final Value<String> customerId;
  final Value<String> status;
  final Value<DateTime> timestamp;
  final Value<double?> capturedLat;
  final Value<double?> capturedLng;
  final Value<double?> accuracyMeters;
  final Value<double?> distanceMeters;
  final Value<int> amount;
  final Value<String?> receiptNumber;
  final Value<String?> notes;
  final Value<String?> skipReason;
  final Value<String> photoPathsJson;
  final Value<String> syncStatus;
  final Value<String> userId;
  final Value<String> userName;
  final Value<String> userRole;
  final Value<int> rowid;
  const VisitsCompanion({
    this.id = const Value.absent(),
    this.tripId = const Value.absent(),
    this.customerId = const Value.absent(),
    this.status = const Value.absent(),
    this.timestamp = const Value.absent(),
    this.capturedLat = const Value.absent(),
    this.capturedLng = const Value.absent(),
    this.accuracyMeters = const Value.absent(),
    this.distanceMeters = const Value.absent(),
    this.amount = const Value.absent(),
    this.receiptNumber = const Value.absent(),
    this.notes = const Value.absent(),
    this.skipReason = const Value.absent(),
    this.photoPathsJson = const Value.absent(),
    this.syncStatus = const Value.absent(),
    this.userId = const Value.absent(),
    this.userName = const Value.absent(),
    this.userRole = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  VisitsCompanion.insert({
    required String id,
    required String tripId,
    required String customerId,
    required String status,
    required DateTime timestamp,
    this.capturedLat = const Value.absent(),
    this.capturedLng = const Value.absent(),
    this.accuracyMeters = const Value.absent(),
    this.distanceMeters = const Value.absent(),
    this.amount = const Value.absent(),
    this.receiptNumber = const Value.absent(),
    this.notes = const Value.absent(),
    this.skipReason = const Value.absent(),
    this.photoPathsJson = const Value.absent(),
    this.syncStatus = const Value.absent(),
    this.userId = const Value.absent(),
    this.userName = const Value.absent(),
    this.userRole = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        tripId = Value(tripId),
        customerId = Value(customerId),
        status = Value(status),
        timestamp = Value(timestamp);
  static Insertable<VisitsData> custom({
    Expression<String>? id,
    Expression<String>? tripId,
    Expression<String>? customerId,
    Expression<String>? status,
    Expression<DateTime>? timestamp,
    Expression<double>? capturedLat,
    Expression<double>? capturedLng,
    Expression<double>? accuracyMeters,
    Expression<double>? distanceMeters,
    Expression<int>? amount,
    Expression<String>? receiptNumber,
    Expression<String>? notes,
    Expression<String>? skipReason,
    Expression<String>? photoPathsJson,
    Expression<String>? syncStatus,
    Expression<String>? userId,
    Expression<String>? userName,
    Expression<String>? userRole,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (tripId != null) 'trip_id': tripId,
      if (customerId != null) 'customer_id': customerId,
      if (status != null) 'status': status,
      if (timestamp != null) 'timestamp': timestamp,
      if (capturedLat != null) 'captured_lat': capturedLat,
      if (capturedLng != null) 'captured_lng': capturedLng,
      if (accuracyMeters != null) 'accuracy_meters': accuracyMeters,
      if (distanceMeters != null) 'distance_meters': distanceMeters,
      if (amount != null) 'amount': amount,
      if (receiptNumber != null) 'receipt_number': receiptNumber,
      if (notes != null) 'notes': notes,
      if (skipReason != null) 'skip_reason': skipReason,
      if (photoPathsJson != null) 'photo_paths_json': photoPathsJson,
      if (syncStatus != null) 'sync_status': syncStatus,
      if (userId != null) 'user_id': userId,
      if (userName != null) 'user_name': userName,
      if (userRole != null) 'user_role': userRole,
      if (rowid != null) 'rowid': rowid,
    });
  }

  VisitsCompanion copyWith(
      {Value<String>? id,
      Value<String>? tripId,
      Value<String>? customerId,
      Value<String>? status,
      Value<DateTime>? timestamp,
      Value<double?>? capturedLat,
      Value<double?>? capturedLng,
      Value<double?>? accuracyMeters,
      Value<double?>? distanceMeters,
      Value<int>? amount,
      Value<String?>? receiptNumber,
      Value<String?>? notes,
      Value<String?>? skipReason,
      Value<String>? photoPathsJson,
      Value<String>? syncStatus,
      Value<String>? userId,
      Value<String>? userName,
      Value<String>? userRole,
      Value<int>? rowid}) {
    return VisitsCompanion(
      id: id ?? this.id,
      tripId: tripId ?? this.tripId,
      customerId: customerId ?? this.customerId,
      status: status ?? this.status,
      timestamp: timestamp ?? this.timestamp,
      capturedLat: capturedLat ?? this.capturedLat,
      capturedLng: capturedLng ?? this.capturedLng,
      accuracyMeters: accuracyMeters ?? this.accuracyMeters,
      distanceMeters: distanceMeters ?? this.distanceMeters,
      amount: amount ?? this.amount,
      receiptNumber: receiptNumber ?? this.receiptNumber,
      notes: notes ?? this.notes,
      skipReason: skipReason ?? this.skipReason,
      photoPathsJson: photoPathsJson ?? this.photoPathsJson,
      syncStatus: syncStatus ?? this.syncStatus,
      userId: userId ?? this.userId,
      userName: userName ?? this.userName,
      userRole: userRole ?? this.userRole,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (tripId.present) {
      map['trip_id'] = Variable<String>(tripId.value);
    }
    if (customerId.present) {
      map['customer_id'] = Variable<String>(customerId.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (timestamp.present) {
      map['timestamp'] = Variable<DateTime>(timestamp.value);
    }
    if (capturedLat.present) {
      map['captured_lat'] = Variable<double>(capturedLat.value);
    }
    if (capturedLng.present) {
      map['captured_lng'] = Variable<double>(capturedLng.value);
    }
    if (accuracyMeters.present) {
      map['accuracy_meters'] = Variable<double>(accuracyMeters.value);
    }
    if (distanceMeters.present) {
      map['distance_meters'] = Variable<double>(distanceMeters.value);
    }
    if (amount.present) {
      map['amount'] = Variable<int>(amount.value);
    }
    if (receiptNumber.present) {
      map['receipt_number'] = Variable<String>(receiptNumber.value);
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
    }
    if (skipReason.present) {
      map['skip_reason'] = Variable<String>(skipReason.value);
    }
    if (photoPathsJson.present) {
      map['photo_paths_json'] = Variable<String>(photoPathsJson.value);
    }
    if (syncStatus.present) {
      map['sync_status'] = Variable<String>(syncStatus.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (userName.present) {
      map['user_name'] = Variable<String>(userName.value);
    }
    if (userRole.present) {
      map['user_role'] = Variable<String>(userRole.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('VisitsCompanion(')
          ..write('id: $id, ')
          ..write('tripId: $tripId, ')
          ..write('customerId: $customerId, ')
          ..write('status: $status, ')
          ..write('timestamp: $timestamp, ')
          ..write('capturedLat: $capturedLat, ')
          ..write('capturedLng: $capturedLng, ')
          ..write('accuracyMeters: $accuracyMeters, ')
          ..write('distanceMeters: $distanceMeters, ')
          ..write('amount: $amount, ')
          ..write('receiptNumber: $receiptNumber, ')
          ..write('notes: $notes, ')
          ..write('skipReason: $skipReason, ')
          ..write('photoPathsJson: $photoPathsJson, ')
          ..write('syncStatus: $syncStatus, ')
          ..write('userId: $userId, ')
          ..write('userName: $userName, ')
          ..write('userRole: $userRole, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AppConfigTable extends AppConfig
    with TableInfo<$AppConfigTable, AppConfigData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AppConfigTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
      'key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
      'value', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'app_config';
  @override
  VerificationContext validateIntegrity(Insertable<AppConfigData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
          _keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
          _valueMeta, value.isAcceptableOrUnknown(data['value']!, _valueMeta));
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  AppConfigData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AppConfigData(
      key: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      value: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}value'])!,
    );
  }

  @override
  $AppConfigTable createAlias(String alias) {
    return $AppConfigTable(attachedDatabase, alias);
  }
}

class AppConfigData extends DataClass implements Insertable<AppConfigData> {
  final String key;
  final String value;
  const AppConfigData({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  AppConfigCompanion toCompanion(bool nullToAbsent) {
    return AppConfigCompanion(
      key: Value(key),
      value: Value(value),
    );
  }

  factory AppConfigData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AppConfigData(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  AppConfigData copyWith({String? key, String? value}) => AppConfigData(
        key: key ?? this.key,
        value: value ?? this.value,
      );
  AppConfigData copyWithCompanion(AppConfigCompanion data) {
    return AppConfigData(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AppConfigData(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppConfigData &&
          other.key == this.key &&
          other.value == this.value);
}

class AppConfigCompanion extends UpdateCompanion<AppConfigData> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const AppConfigCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AppConfigCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  })  : key = Value(key),
        value = Value(value);
  static Insertable<AppConfigData> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AppConfigCompanion copyWith(
      {Value<String>? key, Value<String>? value, Value<int>? rowid}) {
    return AppConfigCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AppConfigCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AuditLogsTable extends AuditLogs
    with TableInfo<$AuditLogsTable, AuditLogData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AuditLogsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _entityTypeMeta =
      const VerificationMeta('entityType');
  @override
  late final GeneratedColumn<String> entityType = GeneratedColumn<String>(
      'entity_type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _entityIdMeta =
      const VerificationMeta('entityId');
  @override
  late final GeneratedColumn<String> entityId = GeneratedColumn<String>(
      'entity_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _actionMeta = const VerificationMeta('action');
  @override
  late final GeneratedColumn<String> action = GeneratedColumn<String>(
      'action', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _actorIdMeta =
      const VerificationMeta('actorId');
  @override
  late final GeneratedColumn<String> actorId = GeneratedColumn<String>(
      'actor_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _actorNameMeta =
      const VerificationMeta('actorName');
  @override
  late final GeneratedColumn<String> actorName = GeneratedColumn<String>(
      'actor_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _actorRoleMeta =
      const VerificationMeta('actorRole');
  @override
  late final GeneratedColumn<String> actorRole = GeneratedColumn<String>(
      'actor_role', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _timestampMeta =
      const VerificationMeta('timestamp');
  @override
  late final GeneratedColumn<DateTime> timestamp = GeneratedColumn<DateTime>(
      'timestamp', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _diffJsonMeta =
      const VerificationMeta('diffJson');
  @override
  late final GeneratedColumn<String> diffJson = GeneratedColumn<String>(
      'diff_json', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('{}'));
  static const VerificationMeta _summaryMeta =
      const VerificationMeta('summary');
  @override
  late final GeneratedColumn<String> summary = GeneratedColumn<String>(
      'summary', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _orgIdMeta = const VerificationMeta('orgId');
  @override
  late final GeneratedColumn<String> orgId = GeneratedColumn<String>(
      'org_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        entityType,
        entityId,
        action,
        actorId,
        actorName,
        actorRole,
        timestamp,
        diffJson,
        summary,
        orgId
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'audit_logs';
  @override
  VerificationContext validateIntegrity(Insertable<AuditLogData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('entity_type')) {
      context.handle(
          _entityTypeMeta,
          entityType.isAcceptableOrUnknown(
              data['entity_type']!, _entityTypeMeta));
    } else if (isInserting) {
      context.missing(_entityTypeMeta);
    }
    if (data.containsKey('entity_id')) {
      context.handle(_entityIdMeta,
          entityId.isAcceptableOrUnknown(data['entity_id']!, _entityIdMeta));
    } else if (isInserting) {
      context.missing(_entityIdMeta);
    }
    if (data.containsKey('action')) {
      context.handle(_actionMeta,
          action.isAcceptableOrUnknown(data['action']!, _actionMeta));
    } else if (isInserting) {
      context.missing(_actionMeta);
    }
    if (data.containsKey('actor_id')) {
      context.handle(_actorIdMeta,
          actorId.isAcceptableOrUnknown(data['actor_id']!, _actorIdMeta));
    } else if (isInserting) {
      context.missing(_actorIdMeta);
    }
    if (data.containsKey('actor_name')) {
      context.handle(_actorNameMeta,
          actorName.isAcceptableOrUnknown(data['actor_name']!, _actorNameMeta));
    } else if (isInserting) {
      context.missing(_actorNameMeta);
    }
    if (data.containsKey('actor_role')) {
      context.handle(_actorRoleMeta,
          actorRole.isAcceptableOrUnknown(data['actor_role']!, _actorRoleMeta));
    } else if (isInserting) {
      context.missing(_actorRoleMeta);
    }
    if (data.containsKey('timestamp')) {
      context.handle(_timestampMeta,
          timestamp.isAcceptableOrUnknown(data['timestamp']!, _timestampMeta));
    } else if (isInserting) {
      context.missing(_timestampMeta);
    }
    if (data.containsKey('diff_json')) {
      context.handle(_diffJsonMeta,
          diffJson.isAcceptableOrUnknown(data['diff_json']!, _diffJsonMeta));
    }
    if (data.containsKey('summary')) {
      context.handle(_summaryMeta,
          summary.isAcceptableOrUnknown(data['summary']!, _summaryMeta));
    }
    if (data.containsKey('org_id')) {
      context.handle(
          _orgIdMeta, orgId.isAcceptableOrUnknown(data['org_id']!, _orgIdMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AuditLogData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AuditLogData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      entityType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}entity_type'])!,
      entityId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}entity_id'])!,
      action: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}action'])!,
      actorId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}actor_id'])!,
      actorName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}actor_name'])!,
      actorRole: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}actor_role'])!,
      timestamp: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}timestamp'])!,
      diffJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}diff_json'])!,
      summary: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}summary'])!,
      orgId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}org_id']),
    );
  }

  @override
  $AuditLogsTable createAlias(String alias) {
    return $AuditLogsTable(attachedDatabase, alias);
  }
}

class AuditLogData extends DataClass implements Insertable<AuditLogData> {
  final String id;
  final String entityType;
  final String entityId;
  final String action;
  final String actorId;
  final String actorName;
  final String actorRole;
  final DateTime timestamp;
  final String diffJson;
  final String summary;
  final String? orgId;
  const AuditLogData(
      {required this.id,
      required this.entityType,
      required this.entityId,
      required this.action,
      required this.actorId,
      required this.actorName,
      required this.actorRole,
      required this.timestamp,
      required this.diffJson,
      required this.summary,
      this.orgId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['entity_type'] = Variable<String>(entityType);
    map['entity_id'] = Variable<String>(entityId);
    map['action'] = Variable<String>(action);
    map['actor_id'] = Variable<String>(actorId);
    map['actor_name'] = Variable<String>(actorName);
    map['actor_role'] = Variable<String>(actorRole);
    map['timestamp'] = Variable<DateTime>(timestamp);
    map['diff_json'] = Variable<String>(diffJson);
    map['summary'] = Variable<String>(summary);
    if (!nullToAbsent || orgId != null) {
      map['org_id'] = Variable<String>(orgId);
    }
    return map;
  }

  AuditLogsCompanion toCompanion(bool nullToAbsent) {
    return AuditLogsCompanion(
      id: Value(id),
      entityType: Value(entityType),
      entityId: Value(entityId),
      action: Value(action),
      actorId: Value(actorId),
      actorName: Value(actorName),
      actorRole: Value(actorRole),
      timestamp: Value(timestamp),
      diffJson: Value(diffJson),
      summary: Value(summary),
      orgId:
          orgId == null && nullToAbsent ? const Value.absent() : Value(orgId),
    );
  }

  factory AuditLogData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AuditLogData(
      id: serializer.fromJson<String>(json['id']),
      entityType: serializer.fromJson<String>(json['entityType']),
      entityId: serializer.fromJson<String>(json['entityId']),
      action: serializer.fromJson<String>(json['action']),
      actorId: serializer.fromJson<String>(json['actorId']),
      actorName: serializer.fromJson<String>(json['actorName']),
      actorRole: serializer.fromJson<String>(json['actorRole']),
      timestamp: serializer.fromJson<DateTime>(json['timestamp']),
      diffJson: serializer.fromJson<String>(json['diffJson']),
      summary: serializer.fromJson<String>(json['summary']),
      orgId: serializer.fromJson<String?>(json['orgId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'entityType': serializer.toJson<String>(entityType),
      'entityId': serializer.toJson<String>(entityId),
      'action': serializer.toJson<String>(action),
      'actorId': serializer.toJson<String>(actorId),
      'actorName': serializer.toJson<String>(actorName),
      'actorRole': serializer.toJson<String>(actorRole),
      'timestamp': serializer.toJson<DateTime>(timestamp),
      'diffJson': serializer.toJson<String>(diffJson),
      'summary': serializer.toJson<String>(summary),
      'orgId': serializer.toJson<String?>(orgId),
    };
  }

  AuditLogData copyWith(
          {String? id,
          String? entityType,
          String? entityId,
          String? action,
          String? actorId,
          String? actorName,
          String? actorRole,
          DateTime? timestamp,
          String? diffJson,
          String? summary,
          Value<String?> orgId = const Value.absent()}) =>
      AuditLogData(
        id: id ?? this.id,
        entityType: entityType ?? this.entityType,
        entityId: entityId ?? this.entityId,
        action: action ?? this.action,
        actorId: actorId ?? this.actorId,
        actorName: actorName ?? this.actorName,
        actorRole: actorRole ?? this.actorRole,
        timestamp: timestamp ?? this.timestamp,
        diffJson: diffJson ?? this.diffJson,
        summary: summary ?? this.summary,
        orgId: orgId.present ? orgId.value : this.orgId,
      );
  AuditLogData copyWithCompanion(AuditLogsCompanion data) {
    return AuditLogData(
      id: data.id.present ? data.id.value : this.id,
      entityType:
          data.entityType.present ? data.entityType.value : this.entityType,
      entityId: data.entityId.present ? data.entityId.value : this.entityId,
      action: data.action.present ? data.action.value : this.action,
      actorId: data.actorId.present ? data.actorId.value : this.actorId,
      actorName: data.actorName.present ? data.actorName.value : this.actorName,
      actorRole: data.actorRole.present ? data.actorRole.value : this.actorRole,
      timestamp: data.timestamp.present ? data.timestamp.value : this.timestamp,
      diffJson: data.diffJson.present ? data.diffJson.value : this.diffJson,
      summary: data.summary.present ? data.summary.value : this.summary,
      orgId: data.orgId.present ? data.orgId.value : this.orgId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AuditLogData(')
          ..write('id: $id, ')
          ..write('entityType: $entityType, ')
          ..write('entityId: $entityId, ')
          ..write('action: $action, ')
          ..write('actorId: $actorId, ')
          ..write('actorName: $actorName, ')
          ..write('actorRole: $actorRole, ')
          ..write('timestamp: $timestamp, ')
          ..write('diffJson: $diffJson, ')
          ..write('summary: $summary, ')
          ..write('orgId: $orgId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, entityType, entityId, action, actorId,
      actorName, actorRole, timestamp, diffJson, summary, orgId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AuditLogData &&
          other.id == this.id &&
          other.entityType == this.entityType &&
          other.entityId == this.entityId &&
          other.action == this.action &&
          other.actorId == this.actorId &&
          other.actorName == this.actorName &&
          other.actorRole == this.actorRole &&
          other.timestamp == this.timestamp &&
          other.diffJson == this.diffJson &&
          other.summary == this.summary &&
          other.orgId == this.orgId);
}

class AuditLogsCompanion extends UpdateCompanion<AuditLogData> {
  final Value<String> id;
  final Value<String> entityType;
  final Value<String> entityId;
  final Value<String> action;
  final Value<String> actorId;
  final Value<String> actorName;
  final Value<String> actorRole;
  final Value<DateTime> timestamp;
  final Value<String> diffJson;
  final Value<String> summary;
  final Value<String?> orgId;
  final Value<int> rowid;
  const AuditLogsCompanion({
    this.id = const Value.absent(),
    this.entityType = const Value.absent(),
    this.entityId = const Value.absent(),
    this.action = const Value.absent(),
    this.actorId = const Value.absent(),
    this.actorName = const Value.absent(),
    this.actorRole = const Value.absent(),
    this.timestamp = const Value.absent(),
    this.diffJson = const Value.absent(),
    this.summary = const Value.absent(),
    this.orgId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AuditLogsCompanion.insert({
    required String id,
    required String entityType,
    required String entityId,
    required String action,
    required String actorId,
    required String actorName,
    required String actorRole,
    required DateTime timestamp,
    this.diffJson = const Value.absent(),
    this.summary = const Value.absent(),
    this.orgId = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        entityType = Value(entityType),
        entityId = Value(entityId),
        action = Value(action),
        actorId = Value(actorId),
        actorName = Value(actorName),
        actorRole = Value(actorRole),
        timestamp = Value(timestamp);
  static Insertable<AuditLogData> custom({
    Expression<String>? id,
    Expression<String>? entityType,
    Expression<String>? entityId,
    Expression<String>? action,
    Expression<String>? actorId,
    Expression<String>? actorName,
    Expression<String>? actorRole,
    Expression<DateTime>? timestamp,
    Expression<String>? diffJson,
    Expression<String>? summary,
    Expression<String>? orgId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (entityType != null) 'entity_type': entityType,
      if (entityId != null) 'entity_id': entityId,
      if (action != null) 'action': action,
      if (actorId != null) 'actor_id': actorId,
      if (actorName != null) 'actor_name': actorName,
      if (actorRole != null) 'actor_role': actorRole,
      if (timestamp != null) 'timestamp': timestamp,
      if (diffJson != null) 'diff_json': diffJson,
      if (summary != null) 'summary': summary,
      if (orgId != null) 'org_id': orgId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AuditLogsCompanion copyWith(
      {Value<String>? id,
      Value<String>? entityType,
      Value<String>? entityId,
      Value<String>? action,
      Value<String>? actorId,
      Value<String>? actorName,
      Value<String>? actorRole,
      Value<DateTime>? timestamp,
      Value<String>? diffJson,
      Value<String>? summary,
      Value<String?>? orgId,
      Value<int>? rowid}) {
    return AuditLogsCompanion(
      id: id ?? this.id,
      entityType: entityType ?? this.entityType,
      entityId: entityId ?? this.entityId,
      action: action ?? this.action,
      actorId: actorId ?? this.actorId,
      actorName: actorName ?? this.actorName,
      actorRole: actorRole ?? this.actorRole,
      timestamp: timestamp ?? this.timestamp,
      diffJson: diffJson ?? this.diffJson,
      summary: summary ?? this.summary,
      orgId: orgId ?? this.orgId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (entityType.present) {
      map['entity_type'] = Variable<String>(entityType.value);
    }
    if (entityId.present) {
      map['entity_id'] = Variable<String>(entityId.value);
    }
    if (action.present) {
      map['action'] = Variable<String>(action.value);
    }
    if (actorId.present) {
      map['actor_id'] = Variable<String>(actorId.value);
    }
    if (actorName.present) {
      map['actor_name'] = Variable<String>(actorName.value);
    }
    if (actorRole.present) {
      map['actor_role'] = Variable<String>(actorRole.value);
    }
    if (timestamp.present) {
      map['timestamp'] = Variable<DateTime>(timestamp.value);
    }
    if (diffJson.present) {
      map['diff_json'] = Variable<String>(diffJson.value);
    }
    if (summary.present) {
      map['summary'] = Variable<String>(summary.value);
    }
    if (orgId.present) {
      map['org_id'] = Variable<String>(orgId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AuditLogsCompanion(')
          ..write('id: $id, ')
          ..write('entityType: $entityType, ')
          ..write('entityId: $entityId, ')
          ..write('action: $action, ')
          ..write('actorId: $actorId, ')
          ..write('actorName: $actorName, ')
          ..write('actorRole: $actorRole, ')
          ..write('timestamp: $timestamp, ')
          ..write('diffJson: $diffJson, ')
          ..write('summary: $summary, ')
          ..write('orgId: $orgId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $UsersTable extends Users with TableInfo<$UsersTable, UsersData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $UsersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _emailMeta = const VerificationMeta('email');
  @override
  late final GeneratedColumn<String> email = GeneratedColumn<String>(
      'email', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _phoneMeta = const VerificationMeta('phone');
  @override
  late final GeneratedColumn<String> phone = GeneratedColumn<String>(
      'phone', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _roleMeta = const VerificationMeta('role');
  @override
  late final GeneratedColumn<String> role = GeneratedColumn<String>(
      'role', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _isActiveMeta =
      const VerificationMeta('isActive');
  @override
  late final GeneratedColumn<bool> isActive = GeneratedColumn<bool>(
      'is_active', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_active" IN (0, 1))'),
      defaultValue: const Constant(true));
  static const VerificationMeta _passwordHashMeta =
      const VerificationMeta('passwordHash');
  @override
  late final GeneratedColumn<String> passwordHash = GeneratedColumn<String>(
      'password_hash', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _passwordSaltMeta =
      const VerificationMeta('passwordSalt');
  @override
  late final GeneratedColumn<String> passwordSalt = GeneratedColumn<String>(
      'password_salt', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _passwordTemporaryMeta =
      const VerificationMeta('passwordTemporary');
  @override
  late final GeneratedColumn<bool> passwordTemporary = GeneratedColumn<bool>(
      'password_temporary', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("password_temporary" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _orgIdMeta = const VerificationMeta('orgId');
  @override
  late final GeneratedColumn<String> orgId = GeneratedColumn<String>(
      'org_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _fcmTokenMeta =
      const VerificationMeta('fcmToken');
  @override
  late final GeneratedColumn<String> fcmToken = GeneratedColumn<String>(
      'fcm_token', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        name,
        email,
        phone,
        role,
        isActive,
        passwordHash,
        passwordSalt,
        createdAt,
        updatedAt,
        passwordTemporary,
        orgId,
        fcmToken
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'users';
  @override
  VerificationContext validateIntegrity(Insertable<UsersData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('email')) {
      context.handle(
          _emailMeta, email.isAcceptableOrUnknown(data['email']!, _emailMeta));
    } else if (isInserting) {
      context.missing(_emailMeta);
    }
    if (data.containsKey('phone')) {
      context.handle(
          _phoneMeta, phone.isAcceptableOrUnknown(data['phone']!, _phoneMeta));
    }
    if (data.containsKey('role')) {
      context.handle(
          _roleMeta, role.isAcceptableOrUnknown(data['role']!, _roleMeta));
    } else if (isInserting) {
      context.missing(_roleMeta);
    }
    if (data.containsKey('is_active')) {
      context.handle(_isActiveMeta,
          isActive.isAcceptableOrUnknown(data['is_active']!, _isActiveMeta));
    }
    if (data.containsKey('password_hash')) {
      context.handle(
          _passwordHashMeta,
          passwordHash.isAcceptableOrUnknown(
              data['password_hash']!, _passwordHashMeta));
    }
    if (data.containsKey('password_salt')) {
      context.handle(
          _passwordSaltMeta,
          passwordSalt.isAcceptableOrUnknown(
              data['password_salt']!, _passwordSaltMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    if (data.containsKey('password_temporary')) {
      context.handle(
          _passwordTemporaryMeta,
          passwordTemporary.isAcceptableOrUnknown(
              data['password_temporary']!, _passwordTemporaryMeta));
    }
    if (data.containsKey('org_id')) {
      context.handle(
          _orgIdMeta, orgId.isAcceptableOrUnknown(data['org_id']!, _orgIdMeta));
    }
    if (data.containsKey('fcm_token')) {
      context.handle(_fcmTokenMeta,
          fcmToken.isAcceptableOrUnknown(data['fcm_token']!, _fcmTokenMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  UsersData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return UsersData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      email: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}email'])!,
      phone: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}phone'])!,
      role: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}role'])!,
      isActive: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_active'])!,
      passwordHash: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}password_hash'])!,
      passwordSalt: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}password_salt'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at']),
      passwordTemporary: attachedDatabase.typeMapping.read(
          DriftSqlType.bool, data['${effectivePrefix}password_temporary'])!,
      orgId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}org_id']),
      fcmToken: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}fcm_token']),
    );
  }

  @override
  $UsersTable createAlias(String alias) {
    return $UsersTable(attachedDatabase, alias);
  }
}

class UsersData extends DataClass implements Insertable<UsersData> {
  final String id;
  final String name;
  final String email;
  final String phone;
  final String role;
  final bool isActive;

  /// Hex-encoded SHA-256(salt + password).
  final String passwordHash;
  final String passwordSalt;
  final DateTime createdAt;
  final DateTime? updatedAt;

  /// True if the user was created via a password reset and hasn't chosen
  /// their own password yet. UI can prompt them to change it.
  final bool passwordTemporary;

  /// The organization this user belongs to. Nullable for users created
  /// before multi-tenancy was introduced (they implicitly belong to the
  /// default/primary org) and for the super admin, who is app-level and
  /// does not belong to any single org.
  final String? orgId;
  final String? fcmToken;
  const UsersData(
      {required this.id,
      required this.name,
      required this.email,
      required this.phone,
      required this.role,
      required this.isActive,
      required this.passwordHash,
      required this.passwordSalt,
      required this.createdAt,
      this.updatedAt,
      required this.passwordTemporary,
      this.orgId,
      this.fcmToken});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['email'] = Variable<String>(email);
    map['phone'] = Variable<String>(phone);
    map['role'] = Variable<String>(role);
    map['is_active'] = Variable<bool>(isActive);
    map['password_hash'] = Variable<String>(passwordHash);
    map['password_salt'] = Variable<String>(passwordSalt);
    map['created_at'] = Variable<DateTime>(createdAt);
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    map['password_temporary'] = Variable<bool>(passwordTemporary);
    if (!nullToAbsent || orgId != null) {
      map['org_id'] = Variable<String>(orgId);
    }
    if (!nullToAbsent || fcmToken != null) {
      map['fcm_token'] = Variable<String>(fcmToken);
    }
    return map;
  }

  UsersCompanion toCompanion(bool nullToAbsent) {
    return UsersCompanion(
      id: Value(id),
      name: Value(name),
      email: Value(email),
      phone: Value(phone),
      role: Value(role),
      isActive: Value(isActive),
      passwordHash: Value(passwordHash),
      passwordSalt: Value(passwordSalt),
      createdAt: Value(createdAt),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
      passwordTemporary: Value(passwordTemporary),
      orgId:
          orgId == null && nullToAbsent ? const Value.absent() : Value(orgId),
      fcmToken: fcmToken == null && nullToAbsent
          ? const Value.absent()
          : Value(fcmToken),
    );
  }

  factory UsersData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return UsersData(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      email: serializer.fromJson<String>(json['email']),
      phone: serializer.fromJson<String>(json['phone']),
      role: serializer.fromJson<String>(json['role']),
      isActive: serializer.fromJson<bool>(json['isActive']),
      passwordHash: serializer.fromJson<String>(json['passwordHash']),
      passwordSalt: serializer.fromJson<String>(json['passwordSalt']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
      passwordTemporary: serializer.fromJson<bool>(json['passwordTemporary']),
      orgId: serializer.fromJson<String?>(json['orgId']),
      fcmToken: serializer.fromJson<String?>(json['fcmToken']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'email': serializer.toJson<String>(email),
      'phone': serializer.toJson<String>(phone),
      'role': serializer.toJson<String>(role),
      'isActive': serializer.toJson<bool>(isActive),
      'passwordHash': serializer.toJson<String>(passwordHash),
      'passwordSalt': serializer.toJson<String>(passwordSalt),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
      'passwordTemporary': serializer.toJson<bool>(passwordTemporary),
      'orgId': serializer.toJson<String?>(orgId),
      'fcmToken': serializer.toJson<String?>(fcmToken),
    };
  }

  UsersData copyWith(
          {String? id,
          String? name,
          String? email,
          String? phone,
          String? role,
          bool? isActive,
          String? passwordHash,
          String? passwordSalt,
          DateTime? createdAt,
          Value<DateTime?> updatedAt = const Value.absent(),
          bool? passwordTemporary,
          Value<String?> orgId = const Value.absent(),
          Value<String?> fcmToken = const Value.absent()}) =>
      UsersData(
        id: id ?? this.id,
        name: name ?? this.name,
        email: email ?? this.email,
        phone: phone ?? this.phone,
        role: role ?? this.role,
        isActive: isActive ?? this.isActive,
        passwordHash: passwordHash ?? this.passwordHash,
        passwordSalt: passwordSalt ?? this.passwordSalt,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
        passwordTemporary: passwordTemporary ?? this.passwordTemporary,
        orgId: orgId.present ? orgId.value : this.orgId,
        fcmToken: fcmToken.present ? fcmToken.value : this.fcmToken,
      );
  UsersData copyWithCompanion(UsersCompanion data) {
    return UsersData(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      email: data.email.present ? data.email.value : this.email,
      phone: data.phone.present ? data.phone.value : this.phone,
      role: data.role.present ? data.role.value : this.role,
      isActive: data.isActive.present ? data.isActive.value : this.isActive,
      passwordHash: data.passwordHash.present
          ? data.passwordHash.value
          : this.passwordHash,
      passwordSalt: data.passwordSalt.present
          ? data.passwordSalt.value
          : this.passwordSalt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      passwordTemporary: data.passwordTemporary.present
          ? data.passwordTemporary.value
          : this.passwordTemporary,
      orgId: data.orgId.present ? data.orgId.value : this.orgId,
      fcmToken: data.fcmToken.present ? data.fcmToken.value : this.fcmToken,
    );
  }

  @override
  String toString() {
    return (StringBuffer('UsersData(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('email: $email, ')
          ..write('phone: $phone, ')
          ..write('role: $role, ')
          ..write('isActive: $isActive, ')
          ..write('passwordHash: $passwordHash, ')
          ..write('passwordSalt: $passwordSalt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('passwordTemporary: $passwordTemporary, ')
          ..write('orgId: $orgId, ')
          ..write('fcmToken: $fcmToken')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      name,
      email,
      phone,
      role,
      isActive,
      passwordHash,
      passwordSalt,
      createdAt,
      updatedAt,
      passwordTemporary,
      orgId,
      fcmToken);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UsersData &&
          other.id == this.id &&
          other.name == this.name &&
          other.email == this.email &&
          other.phone == this.phone &&
          other.role == this.role &&
          other.isActive == this.isActive &&
          other.passwordHash == this.passwordHash &&
          other.passwordSalt == this.passwordSalt &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.passwordTemporary == this.passwordTemporary &&
          other.orgId == this.orgId &&
          other.fcmToken == this.fcmToken);
}

class UsersCompanion extends UpdateCompanion<UsersData> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> email;
  final Value<String> phone;
  final Value<String> role;
  final Value<bool> isActive;
  final Value<String> passwordHash;
  final Value<String> passwordSalt;
  final Value<DateTime> createdAt;
  final Value<DateTime?> updatedAt;
  final Value<bool> passwordTemporary;
  final Value<String?> orgId;
  final Value<String?> fcmToken;
  final Value<int> rowid;
  const UsersCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.email = const Value.absent(),
    this.phone = const Value.absent(),
    this.role = const Value.absent(),
    this.isActive = const Value.absent(),
    this.passwordHash = const Value.absent(),
    this.passwordSalt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.passwordTemporary = const Value.absent(),
    this.orgId = const Value.absent(),
    this.fcmToken = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  UsersCompanion.insert({
    required String id,
    required String name,
    required String email,
    this.phone = const Value.absent(),
    required String role,
    this.isActive = const Value.absent(),
    this.passwordHash = const Value.absent(),
    this.passwordSalt = const Value.absent(),
    required DateTime createdAt,
    this.updatedAt = const Value.absent(),
    this.passwordTemporary = const Value.absent(),
    this.orgId = const Value.absent(),
    this.fcmToken = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        name = Value(name),
        email = Value(email),
        role = Value(role),
        createdAt = Value(createdAt);
  static Insertable<UsersData> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? email,
    Expression<String>? phone,
    Expression<String>? role,
    Expression<bool>? isActive,
    Expression<String>? passwordHash,
    Expression<String>? passwordSalt,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<bool>? passwordTemporary,
    Expression<String>? orgId,
    Expression<String>? fcmToken,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (email != null) 'email': email,
      if (phone != null) 'phone': phone,
      if (role != null) 'role': role,
      if (isActive != null) 'is_active': isActive,
      if (passwordHash != null) 'password_hash': passwordHash,
      if (passwordSalt != null) 'password_salt': passwordSalt,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (passwordTemporary != null) 'password_temporary': passwordTemporary,
      if (orgId != null) 'org_id': orgId,
      if (fcmToken != null) 'fcm_token': fcmToken,
      if (rowid != null) 'rowid': rowid,
    });
  }

  UsersCompanion copyWith(
      {Value<String>? id,
      Value<String>? name,
      Value<String>? email,
      Value<String>? phone,
      Value<String>? role,
      Value<bool>? isActive,
      Value<String>? passwordHash,
      Value<String>? passwordSalt,
      Value<DateTime>? createdAt,
      Value<DateTime?>? updatedAt,
      Value<bool>? passwordTemporary,
      Value<String?>? orgId,
      Value<String?>? fcmToken,
      Value<int>? rowid}) {
    return UsersCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      role: role ?? this.role,
      isActive: isActive ?? this.isActive,
      passwordHash: passwordHash ?? this.passwordHash,
      passwordSalt: passwordSalt ?? this.passwordSalt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      passwordTemporary: passwordTemporary ?? this.passwordTemporary,
      orgId: orgId ?? this.orgId,
      fcmToken: fcmToken ?? this.fcmToken,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (email.present) {
      map['email'] = Variable<String>(email.value);
    }
    if (phone.present) {
      map['phone'] = Variable<String>(phone.value);
    }
    if (role.present) {
      map['role'] = Variable<String>(role.value);
    }
    if (isActive.present) {
      map['is_active'] = Variable<bool>(isActive.value);
    }
    if (passwordHash.present) {
      map['password_hash'] = Variable<String>(passwordHash.value);
    }
    if (passwordSalt.present) {
      map['password_salt'] = Variable<String>(passwordSalt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (passwordTemporary.present) {
      map['password_temporary'] = Variable<bool>(passwordTemporary.value);
    }
    if (orgId.present) {
      map['org_id'] = Variable<String>(orgId.value);
    }
    if (fcmToken.present) {
      map['fcm_token'] = Variable<String>(fcmToken.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('UsersCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('email: $email, ')
          ..write('phone: $phone, ')
          ..write('role: $role, ')
          ..write('isActive: $isActive, ')
          ..write('passwordHash: $passwordHash, ')
          ..write('passwordSalt: $passwordSalt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('passwordTemporary: $passwordTemporary, ')
          ..write('orgId: $orgId, ')
          ..write('fcmToken: $fcmToken, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RouteAssignmentsTable extends RouteAssignments
    with TableInfo<$RouteAssignmentsTable, RouteAssignmentsData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RouteAssignmentsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
      'user_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _routeIdMeta =
      const VerificationMeta('routeId');
  @override
  late final GeneratedColumn<String> routeId = GeneratedColumn<String>(
      'route_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _assignedAtMeta =
      const VerificationMeta('assignedAt');
  @override
  late final GeneratedColumn<DateTime> assignedAt = GeneratedColumn<DateTime>(
      'assigned_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _assignedByMeta =
      const VerificationMeta('assignedBy');
  @override
  late final GeneratedColumn<String> assignedBy = GeneratedColumn<String>(
      'assigned_by', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  @override
  List<GeneratedColumn> get $columns =>
      [userId, routeId, assignedAt, assignedBy];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'route_assignments';
  @override
  VerificationContext validateIntegrity(
      Insertable<RouteAssignmentsData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('user_id')) {
      context.handle(_userIdMeta,
          userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta));
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('route_id')) {
      context.handle(_routeIdMeta,
          routeId.isAcceptableOrUnknown(data['route_id']!, _routeIdMeta));
    } else if (isInserting) {
      context.missing(_routeIdMeta);
    }
    if (data.containsKey('assigned_at')) {
      context.handle(
          _assignedAtMeta,
          assignedAt.isAcceptableOrUnknown(
              data['assigned_at']!, _assignedAtMeta));
    } else if (isInserting) {
      context.missing(_assignedAtMeta);
    }
    if (data.containsKey('assigned_by')) {
      context.handle(
          _assignedByMeta,
          assignedBy.isAcceptableOrUnknown(
              data['assigned_by']!, _assignedByMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {userId, routeId};
  @override
  RouteAssignmentsData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RouteAssignmentsData(
      userId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}user_id'])!,
      routeId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}route_id'])!,
      assignedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}assigned_at'])!,
      assignedBy: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}assigned_by'])!,
    );
  }

  @override
  $RouteAssignmentsTable createAlias(String alias) {
    return $RouteAssignmentsTable(attachedDatabase, alias);
  }
}

class RouteAssignmentsData extends DataClass
    implements Insertable<RouteAssignmentsData> {
  final String userId;
  final String routeId;
  final DateTime assignedAt;
  final String assignedBy;
  const RouteAssignmentsData(
      {required this.userId,
      required this.routeId,
      required this.assignedAt,
      required this.assignedBy});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['user_id'] = Variable<String>(userId);
    map['route_id'] = Variable<String>(routeId);
    map['assigned_at'] = Variable<DateTime>(assignedAt);
    map['assigned_by'] = Variable<String>(assignedBy);
    return map;
  }

  RouteAssignmentsCompanion toCompanion(bool nullToAbsent) {
    return RouteAssignmentsCompanion(
      userId: Value(userId),
      routeId: Value(routeId),
      assignedAt: Value(assignedAt),
      assignedBy: Value(assignedBy),
    );
  }

  factory RouteAssignmentsData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RouteAssignmentsData(
      userId: serializer.fromJson<String>(json['userId']),
      routeId: serializer.fromJson<String>(json['routeId']),
      assignedAt: serializer.fromJson<DateTime>(json['assignedAt']),
      assignedBy: serializer.fromJson<String>(json['assignedBy']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'userId': serializer.toJson<String>(userId),
      'routeId': serializer.toJson<String>(routeId),
      'assignedAt': serializer.toJson<DateTime>(assignedAt),
      'assignedBy': serializer.toJson<String>(assignedBy),
    };
  }

  RouteAssignmentsData copyWith(
          {String? userId,
          String? routeId,
          DateTime? assignedAt,
          String? assignedBy}) =>
      RouteAssignmentsData(
        userId: userId ?? this.userId,
        routeId: routeId ?? this.routeId,
        assignedAt: assignedAt ?? this.assignedAt,
        assignedBy: assignedBy ?? this.assignedBy,
      );
  RouteAssignmentsData copyWithCompanion(RouteAssignmentsCompanion data) {
    return RouteAssignmentsData(
      userId: data.userId.present ? data.userId.value : this.userId,
      routeId: data.routeId.present ? data.routeId.value : this.routeId,
      assignedAt:
          data.assignedAt.present ? data.assignedAt.value : this.assignedAt,
      assignedBy:
          data.assignedBy.present ? data.assignedBy.value : this.assignedBy,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RouteAssignmentsData(')
          ..write('userId: $userId, ')
          ..write('routeId: $routeId, ')
          ..write('assignedAt: $assignedAt, ')
          ..write('assignedBy: $assignedBy')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(userId, routeId, assignedAt, assignedBy);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RouteAssignmentsData &&
          other.userId == this.userId &&
          other.routeId == this.routeId &&
          other.assignedAt == this.assignedAt &&
          other.assignedBy == this.assignedBy);
}

class RouteAssignmentsCompanion extends UpdateCompanion<RouteAssignmentsData> {
  final Value<String> userId;
  final Value<String> routeId;
  final Value<DateTime> assignedAt;
  final Value<String> assignedBy;
  final Value<int> rowid;
  const RouteAssignmentsCompanion({
    this.userId = const Value.absent(),
    this.routeId = const Value.absent(),
    this.assignedAt = const Value.absent(),
    this.assignedBy = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RouteAssignmentsCompanion.insert({
    required String userId,
    required String routeId,
    required DateTime assignedAt,
    this.assignedBy = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : userId = Value(userId),
        routeId = Value(routeId),
        assignedAt = Value(assignedAt);
  static Insertable<RouteAssignmentsData> custom({
    Expression<String>? userId,
    Expression<String>? routeId,
    Expression<DateTime>? assignedAt,
    Expression<String>? assignedBy,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (userId != null) 'user_id': userId,
      if (routeId != null) 'route_id': routeId,
      if (assignedAt != null) 'assigned_at': assignedAt,
      if (assignedBy != null) 'assigned_by': assignedBy,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RouteAssignmentsCompanion copyWith(
      {Value<String>? userId,
      Value<String>? routeId,
      Value<DateTime>? assignedAt,
      Value<String>? assignedBy,
      Value<int>? rowid}) {
    return RouteAssignmentsCompanion(
      userId: userId ?? this.userId,
      routeId: routeId ?? this.routeId,
      assignedAt: assignedAt ?? this.assignedAt,
      assignedBy: assignedBy ?? this.assignedBy,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (routeId.present) {
      map['route_id'] = Variable<String>(routeId.value);
    }
    if (assignedAt.present) {
      map['assigned_at'] = Variable<DateTime>(assignedAt.value);
    }
    if (assignedBy.present) {
      map['assigned_by'] = Variable<String>(assignedBy.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RouteAssignmentsCompanion(')
          ..write('userId: $userId, ')
          ..write('routeId: $routeId, ')
          ..write('assignedAt: $assignedAt, ')
          ..write('assignedBy: $assignedBy, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $UploadQueueTable extends UploadQueue
    with TableInfo<$UploadQueueTable, UploadQueueData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $UploadQueueTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _localPathMeta =
      const VerificationMeta('localPath');
  @override
  late final GeneratedColumn<String> localPath = GeneratedColumn<String>(
      'local_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _remotePathMeta =
      const VerificationMeta('remotePath');
  @override
  late final GeneratedColumn<String> remotePath = GeneratedColumn<String>(
      'remote_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _bucketMeta = const VerificationMeta('bucket');
  @override
  late final GeneratedColumn<String> bucket = GeneratedColumn<String>(
      'bucket', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
      'status', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('queued'));
  static const VerificationMeta _retryCountMeta =
      const VerificationMeta('retryCount');
  @override
  late final GeneratedColumn<int> retryCount = GeneratedColumn<int>(
      'retry_count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _lastErrorMeta =
      const VerificationMeta('lastError');
  @override
  late final GeneratedColumn<String> lastError = GeneratedColumn<String>(
      'last_error', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _entityTypeMeta =
      const VerificationMeta('entityType');
  @override
  late final GeneratedColumn<String> entityType = GeneratedColumn<String>(
      'entity_type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _entityIdMeta =
      const VerificationMeta('entityId');
  @override
  late final GeneratedColumn<String> entityId = GeneratedColumn<String>(
      'entity_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        localPath,
        remotePath,
        bucket,
        status,
        retryCount,
        lastError,
        entityType,
        entityId,
        createdAt,
        updatedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'upload_queue';
  @override
  VerificationContext validateIntegrity(Insertable<UploadQueueData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('local_path')) {
      context.handle(_localPathMeta,
          localPath.isAcceptableOrUnknown(data['local_path']!, _localPathMeta));
    } else if (isInserting) {
      context.missing(_localPathMeta);
    }
    if (data.containsKey('remote_path')) {
      context.handle(
          _remotePathMeta,
          remotePath.isAcceptableOrUnknown(
              data['remote_path']!, _remotePathMeta));
    } else if (isInserting) {
      context.missing(_remotePathMeta);
    }
    if (data.containsKey('bucket')) {
      context.handle(_bucketMeta,
          bucket.isAcceptableOrUnknown(data['bucket']!, _bucketMeta));
    } else if (isInserting) {
      context.missing(_bucketMeta);
    }
    if (data.containsKey('status')) {
      context.handle(_statusMeta,
          status.isAcceptableOrUnknown(data['status']!, _statusMeta));
    }
    if (data.containsKey('retry_count')) {
      context.handle(
          _retryCountMeta,
          retryCount.isAcceptableOrUnknown(
              data['retry_count']!, _retryCountMeta));
    }
    if (data.containsKey('last_error')) {
      context.handle(_lastErrorMeta,
          lastError.isAcceptableOrUnknown(data['last_error']!, _lastErrorMeta));
    }
    if (data.containsKey('entity_type')) {
      context.handle(
          _entityTypeMeta,
          entityType.isAcceptableOrUnknown(
              data['entity_type']!, _entityTypeMeta));
    } else if (isInserting) {
      context.missing(_entityTypeMeta);
    }
    if (data.containsKey('entity_id')) {
      context.handle(_entityIdMeta,
          entityId.isAcceptableOrUnknown(data['entity_id']!, _entityIdMeta));
    } else if (isInserting) {
      context.missing(_entityIdMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  UploadQueueData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return UploadQueueData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      localPath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}local_path'])!,
      remotePath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}remote_path'])!,
      bucket: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}bucket'])!,
      status: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}status'])!,
      retryCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}retry_count'])!,
      lastError: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}last_error']),
      entityType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}entity_type'])!,
      entityId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}entity_id'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $UploadQueueTable createAlias(String alias) {
    return $UploadQueueTable(attachedDatabase, alias);
  }
}

class UploadQueueData extends DataClass implements Insertable<UploadQueueData> {
  final String id;

  /// Absolute path on device at the time of queueing. The worker reads
  /// from this path; if the file is gone by then we fail the row.
  final String localPath;

  /// Target object path inside the storage bucket. Convention:
  /// `{orgId}/{entityType}/{entityId}/{filename}`. App-side generated.
  final String remotePath;
  final String bucket;
  final String status;
  final int retryCount;
  final String? lastError;

  /// Loose FK for "what does this upload belong to" — used by UI later
  /// to show photos against a visit/delivery without a join table.
  final String entityType;
  final String entityId;
  final DateTime createdAt;
  final DateTime updatedAt;
  const UploadQueueData(
      {required this.id,
      required this.localPath,
      required this.remotePath,
      required this.bucket,
      required this.status,
      required this.retryCount,
      this.lastError,
      required this.entityType,
      required this.entityId,
      required this.createdAt,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['local_path'] = Variable<String>(localPath);
    map['remote_path'] = Variable<String>(remotePath);
    map['bucket'] = Variable<String>(bucket);
    map['status'] = Variable<String>(status);
    map['retry_count'] = Variable<int>(retryCount);
    if (!nullToAbsent || lastError != null) {
      map['last_error'] = Variable<String>(lastError);
    }
    map['entity_type'] = Variable<String>(entityType);
    map['entity_id'] = Variable<String>(entityId);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  UploadQueueCompanion toCompanion(bool nullToAbsent) {
    return UploadQueueCompanion(
      id: Value(id),
      localPath: Value(localPath),
      remotePath: Value(remotePath),
      bucket: Value(bucket),
      status: Value(status),
      retryCount: Value(retryCount),
      lastError: lastError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastError),
      entityType: Value(entityType),
      entityId: Value(entityId),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory UploadQueueData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return UploadQueueData(
      id: serializer.fromJson<String>(json['id']),
      localPath: serializer.fromJson<String>(json['localPath']),
      remotePath: serializer.fromJson<String>(json['remotePath']),
      bucket: serializer.fromJson<String>(json['bucket']),
      status: serializer.fromJson<String>(json['status']),
      retryCount: serializer.fromJson<int>(json['retryCount']),
      lastError: serializer.fromJson<String?>(json['lastError']),
      entityType: serializer.fromJson<String>(json['entityType']),
      entityId: serializer.fromJson<String>(json['entityId']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'localPath': serializer.toJson<String>(localPath),
      'remotePath': serializer.toJson<String>(remotePath),
      'bucket': serializer.toJson<String>(bucket),
      'status': serializer.toJson<String>(status),
      'retryCount': serializer.toJson<int>(retryCount),
      'lastError': serializer.toJson<String?>(lastError),
      'entityType': serializer.toJson<String>(entityType),
      'entityId': serializer.toJson<String>(entityId),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  UploadQueueData copyWith(
          {String? id,
          String? localPath,
          String? remotePath,
          String? bucket,
          String? status,
          int? retryCount,
          Value<String?> lastError = const Value.absent(),
          String? entityType,
          String? entityId,
          DateTime? createdAt,
          DateTime? updatedAt}) =>
      UploadQueueData(
        id: id ?? this.id,
        localPath: localPath ?? this.localPath,
        remotePath: remotePath ?? this.remotePath,
        bucket: bucket ?? this.bucket,
        status: status ?? this.status,
        retryCount: retryCount ?? this.retryCount,
        lastError: lastError.present ? lastError.value : this.lastError,
        entityType: entityType ?? this.entityType,
        entityId: entityId ?? this.entityId,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  UploadQueueData copyWithCompanion(UploadQueueCompanion data) {
    return UploadQueueData(
      id: data.id.present ? data.id.value : this.id,
      localPath: data.localPath.present ? data.localPath.value : this.localPath,
      remotePath:
          data.remotePath.present ? data.remotePath.value : this.remotePath,
      bucket: data.bucket.present ? data.bucket.value : this.bucket,
      status: data.status.present ? data.status.value : this.status,
      retryCount:
          data.retryCount.present ? data.retryCount.value : this.retryCount,
      lastError: data.lastError.present ? data.lastError.value : this.lastError,
      entityType:
          data.entityType.present ? data.entityType.value : this.entityType,
      entityId: data.entityId.present ? data.entityId.value : this.entityId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('UploadQueueData(')
          ..write('id: $id, ')
          ..write('localPath: $localPath, ')
          ..write('remotePath: $remotePath, ')
          ..write('bucket: $bucket, ')
          ..write('status: $status, ')
          ..write('retryCount: $retryCount, ')
          ..write('lastError: $lastError, ')
          ..write('entityType: $entityType, ')
          ..write('entityId: $entityId, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, localPath, remotePath, bucket, status,
      retryCount, lastError, entityType, entityId, createdAt, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UploadQueueData &&
          other.id == this.id &&
          other.localPath == this.localPath &&
          other.remotePath == this.remotePath &&
          other.bucket == this.bucket &&
          other.status == this.status &&
          other.retryCount == this.retryCount &&
          other.lastError == this.lastError &&
          other.entityType == this.entityType &&
          other.entityId == this.entityId &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class UploadQueueCompanion extends UpdateCompanion<UploadQueueData> {
  final Value<String> id;
  final Value<String> localPath;
  final Value<String> remotePath;
  final Value<String> bucket;
  final Value<String> status;
  final Value<int> retryCount;
  final Value<String?> lastError;
  final Value<String> entityType;
  final Value<String> entityId;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const UploadQueueCompanion({
    this.id = const Value.absent(),
    this.localPath = const Value.absent(),
    this.remotePath = const Value.absent(),
    this.bucket = const Value.absent(),
    this.status = const Value.absent(),
    this.retryCount = const Value.absent(),
    this.lastError = const Value.absent(),
    this.entityType = const Value.absent(),
    this.entityId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  UploadQueueCompanion.insert({
    required String id,
    required String localPath,
    required String remotePath,
    required String bucket,
    this.status = const Value.absent(),
    this.retryCount = const Value.absent(),
    this.lastError = const Value.absent(),
    required String entityType,
    required String entityId,
    required DateTime createdAt,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        localPath = Value(localPath),
        remotePath = Value(remotePath),
        bucket = Value(bucket),
        entityType = Value(entityType),
        entityId = Value(entityId),
        createdAt = Value(createdAt),
        updatedAt = Value(updatedAt);
  static Insertable<UploadQueueData> custom({
    Expression<String>? id,
    Expression<String>? localPath,
    Expression<String>? remotePath,
    Expression<String>? bucket,
    Expression<String>? status,
    Expression<int>? retryCount,
    Expression<String>? lastError,
    Expression<String>? entityType,
    Expression<String>? entityId,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (localPath != null) 'local_path': localPath,
      if (remotePath != null) 'remote_path': remotePath,
      if (bucket != null) 'bucket': bucket,
      if (status != null) 'status': status,
      if (retryCount != null) 'retry_count': retryCount,
      if (lastError != null) 'last_error': lastError,
      if (entityType != null) 'entity_type': entityType,
      if (entityId != null) 'entity_id': entityId,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  UploadQueueCompanion copyWith(
      {Value<String>? id,
      Value<String>? localPath,
      Value<String>? remotePath,
      Value<String>? bucket,
      Value<String>? status,
      Value<int>? retryCount,
      Value<String?>? lastError,
      Value<String>? entityType,
      Value<String>? entityId,
      Value<DateTime>? createdAt,
      Value<DateTime>? updatedAt,
      Value<int>? rowid}) {
    return UploadQueueCompanion(
      id: id ?? this.id,
      localPath: localPath ?? this.localPath,
      remotePath: remotePath ?? this.remotePath,
      bucket: bucket ?? this.bucket,
      status: status ?? this.status,
      retryCount: retryCount ?? this.retryCount,
      lastError: lastError ?? this.lastError,
      entityType: entityType ?? this.entityType,
      entityId: entityId ?? this.entityId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (localPath.present) {
      map['local_path'] = Variable<String>(localPath.value);
    }
    if (remotePath.present) {
      map['remote_path'] = Variable<String>(remotePath.value);
    }
    if (bucket.present) {
      map['bucket'] = Variable<String>(bucket.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (retryCount.present) {
      map['retry_count'] = Variable<int>(retryCount.value);
    }
    if (lastError.present) {
      map['last_error'] = Variable<String>(lastError.value);
    }
    if (entityType.present) {
      map['entity_type'] = Variable<String>(entityType.value);
    }
    if (entityId.present) {
      map['entity_id'] = Variable<String>(entityId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('UploadQueueCompanion(')
          ..write('id: $id, ')
          ..write('localPath: $localPath, ')
          ..write('remotePath: $remotePath, ')
          ..write('bucket: $bucket, ')
          ..write('status: $status, ')
          ..write('retryCount: $retryCount, ')
          ..write('lastError: $lastError, ')
          ..write('entityType: $entityType, ')
          ..write('entityId: $entityId, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DeliveriesTable extends Deliveries
    with TableInfo<$DeliveriesTable, DeliveriesData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DeliveriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _driverIdMeta =
      const VerificationMeta('driverId');
  @override
  late final GeneratedColumn<String> driverId = GeneratedColumn<String>(
      'driver_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _driverNameMeta =
      const VerificationMeta('driverName');
  @override
  late final GeneratedColumn<String> driverName = GeneratedColumn<String>(
      'driver_name', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _driverRoleMeta =
      const VerificationMeta('driverRole');
  @override
  late final GeneratedColumn<String> driverRole = GeneratedColumn<String>(
      'driver_role', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _createdByMeta =
      const VerificationMeta('createdBy');
  @override
  late final GeneratedColumn<String> createdBy = GeneratedColumn<String>(
      'created_by', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdByNameMeta =
      const VerificationMeta('createdByName');
  @override
  late final GeneratedColumn<String> createdByName = GeneratedColumn<String>(
      'created_by_name', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _createdByRoleMeta =
      const VerificationMeta('createdByRole');
  @override
  late final GeneratedColumn<String> createdByRole = GeneratedColumn<String>(
      'created_by_role', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _startedAtMeta =
      const VerificationMeta('startedAt');
  @override
  late final GeneratedColumn<DateTime> startedAt = GeneratedColumn<DateTime>(
      'started_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _completedAtMeta =
      const VerificationMeta('completedAt');
  @override
  late final GeneratedColumn<DateTime> completedAt = GeneratedColumn<DateTime>(
      'completed_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
      'status', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('draft'));
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
      'notes', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _orgIdMeta = const VerificationMeta('orgId');
  @override
  late final GeneratedColumn<String> orgId = GeneratedColumn<String>(
      'org_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        driverId,
        driverName,
        driverRole,
        createdBy,
        createdByName,
        createdByRole,
        createdAt,
        startedAt,
        completedAt,
        status,
        notes,
        orgId
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'deliveries';
  @override
  VerificationContext validateIntegrity(Insertable<DeliveriesData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('driver_id')) {
      context.handle(_driverIdMeta,
          driverId.isAcceptableOrUnknown(data['driver_id']!, _driverIdMeta));
    }
    if (data.containsKey('driver_name')) {
      context.handle(
          _driverNameMeta,
          driverName.isAcceptableOrUnknown(
              data['driver_name']!, _driverNameMeta));
    }
    if (data.containsKey('driver_role')) {
      context.handle(
          _driverRoleMeta,
          driverRole.isAcceptableOrUnknown(
              data['driver_role']!, _driverRoleMeta));
    }
    if (data.containsKey('created_by')) {
      context.handle(_createdByMeta,
          createdBy.isAcceptableOrUnknown(data['created_by']!, _createdByMeta));
    } else if (isInserting) {
      context.missing(_createdByMeta);
    }
    if (data.containsKey('created_by_name')) {
      context.handle(
          _createdByNameMeta,
          createdByName.isAcceptableOrUnknown(
              data['created_by_name']!, _createdByNameMeta));
    }
    if (data.containsKey('created_by_role')) {
      context.handle(
          _createdByRoleMeta,
          createdByRole.isAcceptableOrUnknown(
              data['created_by_role']!, _createdByRoleMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('started_at')) {
      context.handle(_startedAtMeta,
          startedAt.isAcceptableOrUnknown(data['started_at']!, _startedAtMeta));
    }
    if (data.containsKey('completed_at')) {
      context.handle(
          _completedAtMeta,
          completedAt.isAcceptableOrUnknown(
              data['completed_at']!, _completedAtMeta));
    }
    if (data.containsKey('status')) {
      context.handle(_statusMeta,
          status.isAcceptableOrUnknown(data['status']!, _statusMeta));
    }
    if (data.containsKey('notes')) {
      context.handle(
          _notesMeta, notes.isAcceptableOrUnknown(data['notes']!, _notesMeta));
    }
    if (data.containsKey('org_id')) {
      context.handle(
          _orgIdMeta, orgId.isAcceptableOrUnknown(data['org_id']!, _orgIdMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DeliveriesData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DeliveriesData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      driverId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}driver_id']),
      driverName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}driver_name']),
      driverRole: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}driver_role']),
      createdBy: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}created_by'])!,
      createdByName: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}created_by_name'])!,
      createdByRole: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}created_by_role'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      startedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}started_at']),
      completedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}completed_at']),
      status: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}status'])!,
      notes: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}notes']),
      orgId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}org_id']),
    );
  }

  @override
  $DeliveriesTable createAlias(String alias) {
    return $DeliveriesTable(attachedDatabase, alias);
  }
}

class DeliveriesData extends DataClass implements Insertable<DeliveriesData> {
  final String id;

  /// Who the delivery is assigned to. Null while the delivery is still
  /// a draft without a driver picked.
  final String? driverId;
  final String? driverName;
  final String? driverRole;

  /// Who created the dispatch (admin / master-admin / dispatch-manager).
  final String createdBy;
  final String createdByName;
  final String createdByRole;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final String status;
  final String? notes;
  final String? orgId;
  const DeliveriesData(
      {required this.id,
      this.driverId,
      this.driverName,
      this.driverRole,
      required this.createdBy,
      required this.createdByName,
      required this.createdByRole,
      required this.createdAt,
      this.startedAt,
      this.completedAt,
      required this.status,
      this.notes,
      this.orgId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    if (!nullToAbsent || driverId != null) {
      map['driver_id'] = Variable<String>(driverId);
    }
    if (!nullToAbsent || driverName != null) {
      map['driver_name'] = Variable<String>(driverName);
    }
    if (!nullToAbsent || driverRole != null) {
      map['driver_role'] = Variable<String>(driverRole);
    }
    map['created_by'] = Variable<String>(createdBy);
    map['created_by_name'] = Variable<String>(createdByName);
    map['created_by_role'] = Variable<String>(createdByRole);
    map['created_at'] = Variable<DateTime>(createdAt);
    if (!nullToAbsent || startedAt != null) {
      map['started_at'] = Variable<DateTime>(startedAt);
    }
    if (!nullToAbsent || completedAt != null) {
      map['completed_at'] = Variable<DateTime>(completedAt);
    }
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || notes != null) {
      map['notes'] = Variable<String>(notes);
    }
    if (!nullToAbsent || orgId != null) {
      map['org_id'] = Variable<String>(orgId);
    }
    return map;
  }

  DeliveriesCompanion toCompanion(bool nullToAbsent) {
    return DeliveriesCompanion(
      id: Value(id),
      driverId: driverId == null && nullToAbsent
          ? const Value.absent()
          : Value(driverId),
      driverName: driverName == null && nullToAbsent
          ? const Value.absent()
          : Value(driverName),
      driverRole: driverRole == null && nullToAbsent
          ? const Value.absent()
          : Value(driverRole),
      createdBy: Value(createdBy),
      createdByName: Value(createdByName),
      createdByRole: Value(createdByRole),
      createdAt: Value(createdAt),
      startedAt: startedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(startedAt),
      completedAt: completedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(completedAt),
      status: Value(status),
      notes:
          notes == null && nullToAbsent ? const Value.absent() : Value(notes),
      orgId:
          orgId == null && nullToAbsent ? const Value.absent() : Value(orgId),
    );
  }

  factory DeliveriesData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DeliveriesData(
      id: serializer.fromJson<String>(json['id']),
      driverId: serializer.fromJson<String?>(json['driverId']),
      driverName: serializer.fromJson<String?>(json['driverName']),
      driverRole: serializer.fromJson<String?>(json['driverRole']),
      createdBy: serializer.fromJson<String>(json['createdBy']),
      createdByName: serializer.fromJson<String>(json['createdByName']),
      createdByRole: serializer.fromJson<String>(json['createdByRole']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      startedAt: serializer.fromJson<DateTime?>(json['startedAt']),
      completedAt: serializer.fromJson<DateTime?>(json['completedAt']),
      status: serializer.fromJson<String>(json['status']),
      notes: serializer.fromJson<String?>(json['notes']),
      orgId: serializer.fromJson<String?>(json['orgId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'driverId': serializer.toJson<String?>(driverId),
      'driverName': serializer.toJson<String?>(driverName),
      'driverRole': serializer.toJson<String?>(driverRole),
      'createdBy': serializer.toJson<String>(createdBy),
      'createdByName': serializer.toJson<String>(createdByName),
      'createdByRole': serializer.toJson<String>(createdByRole),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'startedAt': serializer.toJson<DateTime?>(startedAt),
      'completedAt': serializer.toJson<DateTime?>(completedAt),
      'status': serializer.toJson<String>(status),
      'notes': serializer.toJson<String?>(notes),
      'orgId': serializer.toJson<String?>(orgId),
    };
  }

  DeliveriesData copyWith(
          {String? id,
          Value<String?> driverId = const Value.absent(),
          Value<String?> driverName = const Value.absent(),
          Value<String?> driverRole = const Value.absent(),
          String? createdBy,
          String? createdByName,
          String? createdByRole,
          DateTime? createdAt,
          Value<DateTime?> startedAt = const Value.absent(),
          Value<DateTime?> completedAt = const Value.absent(),
          String? status,
          Value<String?> notes = const Value.absent(),
          Value<String?> orgId = const Value.absent()}) =>
      DeliveriesData(
        id: id ?? this.id,
        driverId: driverId.present ? driverId.value : this.driverId,
        driverName: driverName.present ? driverName.value : this.driverName,
        driverRole: driverRole.present ? driverRole.value : this.driverRole,
        createdBy: createdBy ?? this.createdBy,
        createdByName: createdByName ?? this.createdByName,
        createdByRole: createdByRole ?? this.createdByRole,
        createdAt: createdAt ?? this.createdAt,
        startedAt: startedAt.present ? startedAt.value : this.startedAt,
        completedAt: completedAt.present ? completedAt.value : this.completedAt,
        status: status ?? this.status,
        notes: notes.present ? notes.value : this.notes,
        orgId: orgId.present ? orgId.value : this.orgId,
      );
  DeliveriesData copyWithCompanion(DeliveriesCompanion data) {
    return DeliveriesData(
      id: data.id.present ? data.id.value : this.id,
      driverId: data.driverId.present ? data.driverId.value : this.driverId,
      driverName:
          data.driverName.present ? data.driverName.value : this.driverName,
      driverRole:
          data.driverRole.present ? data.driverRole.value : this.driverRole,
      createdBy: data.createdBy.present ? data.createdBy.value : this.createdBy,
      createdByName: data.createdByName.present
          ? data.createdByName.value
          : this.createdByName,
      createdByRole: data.createdByRole.present
          ? data.createdByRole.value
          : this.createdByRole,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      startedAt: data.startedAt.present ? data.startedAt.value : this.startedAt,
      completedAt:
          data.completedAt.present ? data.completedAt.value : this.completedAt,
      status: data.status.present ? data.status.value : this.status,
      notes: data.notes.present ? data.notes.value : this.notes,
      orgId: data.orgId.present ? data.orgId.value : this.orgId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DeliveriesData(')
          ..write('id: $id, ')
          ..write('driverId: $driverId, ')
          ..write('driverName: $driverName, ')
          ..write('driverRole: $driverRole, ')
          ..write('createdBy: $createdBy, ')
          ..write('createdByName: $createdByName, ')
          ..write('createdByRole: $createdByRole, ')
          ..write('createdAt: $createdAt, ')
          ..write('startedAt: $startedAt, ')
          ..write('completedAt: $completedAt, ')
          ..write('status: $status, ')
          ..write('notes: $notes, ')
          ..write('orgId: $orgId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      driverId,
      driverName,
      driverRole,
      createdBy,
      createdByName,
      createdByRole,
      createdAt,
      startedAt,
      completedAt,
      status,
      notes,
      orgId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DeliveriesData &&
          other.id == this.id &&
          other.driverId == this.driverId &&
          other.driverName == this.driverName &&
          other.driverRole == this.driverRole &&
          other.createdBy == this.createdBy &&
          other.createdByName == this.createdByName &&
          other.createdByRole == this.createdByRole &&
          other.createdAt == this.createdAt &&
          other.startedAt == this.startedAt &&
          other.completedAt == this.completedAt &&
          other.status == this.status &&
          other.notes == this.notes &&
          other.orgId == this.orgId);
}

class DeliveriesCompanion extends UpdateCompanion<DeliveriesData> {
  final Value<String> id;
  final Value<String?> driverId;
  final Value<String?> driverName;
  final Value<String?> driverRole;
  final Value<String> createdBy;
  final Value<String> createdByName;
  final Value<String> createdByRole;
  final Value<DateTime> createdAt;
  final Value<DateTime?> startedAt;
  final Value<DateTime?> completedAt;
  final Value<String> status;
  final Value<String?> notes;
  final Value<String?> orgId;
  final Value<int> rowid;
  const DeliveriesCompanion({
    this.id = const Value.absent(),
    this.driverId = const Value.absent(),
    this.driverName = const Value.absent(),
    this.driverRole = const Value.absent(),
    this.createdBy = const Value.absent(),
    this.createdByName = const Value.absent(),
    this.createdByRole = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.completedAt = const Value.absent(),
    this.status = const Value.absent(),
    this.notes = const Value.absent(),
    this.orgId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DeliveriesCompanion.insert({
    required String id,
    this.driverId = const Value.absent(),
    this.driverName = const Value.absent(),
    this.driverRole = const Value.absent(),
    required String createdBy,
    this.createdByName = const Value.absent(),
    this.createdByRole = const Value.absent(),
    required DateTime createdAt,
    this.startedAt = const Value.absent(),
    this.completedAt = const Value.absent(),
    this.status = const Value.absent(),
    this.notes = const Value.absent(),
    this.orgId = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        createdBy = Value(createdBy),
        createdAt = Value(createdAt);
  static Insertable<DeliveriesData> custom({
    Expression<String>? id,
    Expression<String>? driverId,
    Expression<String>? driverName,
    Expression<String>? driverRole,
    Expression<String>? createdBy,
    Expression<String>? createdByName,
    Expression<String>? createdByRole,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? startedAt,
    Expression<DateTime>? completedAt,
    Expression<String>? status,
    Expression<String>? notes,
    Expression<String>? orgId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (driverId != null) 'driver_id': driverId,
      if (driverName != null) 'driver_name': driverName,
      if (driverRole != null) 'driver_role': driverRole,
      if (createdBy != null) 'created_by': createdBy,
      if (createdByName != null) 'created_by_name': createdByName,
      if (createdByRole != null) 'created_by_role': createdByRole,
      if (createdAt != null) 'created_at': createdAt,
      if (startedAt != null) 'started_at': startedAt,
      if (completedAt != null) 'completed_at': completedAt,
      if (status != null) 'status': status,
      if (notes != null) 'notes': notes,
      if (orgId != null) 'org_id': orgId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DeliveriesCompanion copyWith(
      {Value<String>? id,
      Value<String?>? driverId,
      Value<String?>? driverName,
      Value<String?>? driverRole,
      Value<String>? createdBy,
      Value<String>? createdByName,
      Value<String>? createdByRole,
      Value<DateTime>? createdAt,
      Value<DateTime?>? startedAt,
      Value<DateTime?>? completedAt,
      Value<String>? status,
      Value<String?>? notes,
      Value<String?>? orgId,
      Value<int>? rowid}) {
    return DeliveriesCompanion(
      id: id ?? this.id,
      driverId: driverId ?? this.driverId,
      driverName: driverName ?? this.driverName,
      driverRole: driverRole ?? this.driverRole,
      createdBy: createdBy ?? this.createdBy,
      createdByName: createdByName ?? this.createdByName,
      createdByRole: createdByRole ?? this.createdByRole,
      createdAt: createdAt ?? this.createdAt,
      startedAt: startedAt ?? this.startedAt,
      completedAt: completedAt ?? this.completedAt,
      status: status ?? this.status,
      notes: notes ?? this.notes,
      orgId: orgId ?? this.orgId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (driverId.present) {
      map['driver_id'] = Variable<String>(driverId.value);
    }
    if (driverName.present) {
      map['driver_name'] = Variable<String>(driverName.value);
    }
    if (driverRole.present) {
      map['driver_role'] = Variable<String>(driverRole.value);
    }
    if (createdBy.present) {
      map['created_by'] = Variable<String>(createdBy.value);
    }
    if (createdByName.present) {
      map['created_by_name'] = Variable<String>(createdByName.value);
    }
    if (createdByRole.present) {
      map['created_by_role'] = Variable<String>(createdByRole.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (startedAt.present) {
      map['started_at'] = Variable<DateTime>(startedAt.value);
    }
    if (completedAt.present) {
      map['completed_at'] = Variable<DateTime>(completedAt.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
    }
    if (orgId.present) {
      map['org_id'] = Variable<String>(orgId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DeliveriesCompanion(')
          ..write('id: $id, ')
          ..write('driverId: $driverId, ')
          ..write('driverName: $driverName, ')
          ..write('driverRole: $driverRole, ')
          ..write('createdBy: $createdBy, ')
          ..write('createdByName: $createdByName, ')
          ..write('createdByRole: $createdByRole, ')
          ..write('createdAt: $createdAt, ')
          ..write('startedAt: $startedAt, ')
          ..write('completedAt: $completedAt, ')
          ..write('status: $status, ')
          ..write('notes: $notes, ')
          ..write('orgId: $orgId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DeliveryStopsTable extends DeliveryStops
    with TableInfo<$DeliveryStopsTable, DeliveryStopsData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DeliveryStopsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _deliveryIdMeta =
      const VerificationMeta('deliveryId');
  @override
  late final GeneratedColumn<String> deliveryId = GeneratedColumn<String>(
      'delivery_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _customerIdMeta =
      const VerificationMeta('customerId');
  @override
  late final GeneratedColumn<String> customerId = GeneratedColumn<String>(
      'customer_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _customerCodeMeta =
      const VerificationMeta('customerCode');
  @override
  late final GeneratedColumn<String> customerCode = GeneratedColumn<String>(
      'customer_code', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _customerNameMeta =
      const VerificationMeta('customerName');
  @override
  late final GeneratedColumn<String> customerName = GeneratedColumn<String>(
      'customer_name', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _sequenceMeta =
      const VerificationMeta('sequence');
  @override
  late final GeneratedColumn<int> sequence = GeneratedColumn<int>(
      'sequence', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _itemDescriptionMeta =
      const VerificationMeta('itemDescription');
  @override
  late final GeneratedColumn<String> itemDescription = GeneratedColumn<String>(
      'item_description', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _amountMeta = const VerificationMeta('amount');
  @override
  late final GeneratedColumn<int> amount = GeneratedColumn<int>(
      'amount', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _paymentTypeMeta =
      const VerificationMeta('paymentType');
  @override
  late final GeneratedColumn<String> paymentType = GeneratedColumn<String>(
      'payment_type', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('cash'));
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
      'status', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('pending'));
  static const VerificationMeta _deliveredAtMeta =
      const VerificationMeta('deliveredAt');
  @override
  late final GeneratedColumn<DateTime> deliveredAt = GeneratedColumn<DateTime>(
      'delivered_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _failureReasonMeta =
      const VerificationMeta('failureReason');
  @override
  late final GeneratedColumn<String> failureReason = GeneratedColumn<String>(
      'failure_reason', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _cashReceivedMeta =
      const VerificationMeta('cashReceived');
  @override
  late final GeneratedColumn<int> cashReceived = GeneratedColumn<int>(
      'cash_received', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _capturedLatMeta =
      const VerificationMeta('capturedLat');
  @override
  late final GeneratedColumn<double> capturedLat = GeneratedColumn<double>(
      'captured_lat', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _capturedLngMeta =
      const VerificationMeta('capturedLng');
  @override
  late final GeneratedColumn<double> capturedLng = GeneratedColumn<double>(
      'captured_lng', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _distanceMetersMeta =
      const VerificationMeta('distanceMeters');
  @override
  late final GeneratedColumn<int> distanceMeters = GeneratedColumn<int>(
      'distance_meters', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _verificationMeta =
      const VerificationMeta('verification');
  @override
  late final GeneratedColumn<String> verification = GeneratedColumn<String>(
      'verification', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('pending'));
  static const VerificationMeta _syncStatusMeta =
      const VerificationMeta('syncStatus');
  @override
  late final GeneratedColumn<String> syncStatus = GeneratedColumn<String>(
      'sync_status', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('synced'));
  static const VerificationMeta _driverNoteMeta =
      const VerificationMeta('driverNote');
  @override
  late final GeneratedColumn<String> driverNote = GeneratedColumn<String>(
      'driver_note', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _soInvoiceNumberMeta =
      const VerificationMeta('soInvoiceNumber');
  @override
  late final GeneratedColumn<String> soInvoiceNumber = GeneratedColumn<String>(
      'so_invoice_number', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _doIdMeta = const VerificationMeta('doId');
  @override
  late final GeneratedColumn<String> doId = GeneratedColumn<String>(
      'do_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _photoPathsJsonMeta =
      const VerificationMeta('photoPathsJson');
  @override
  late final GeneratedColumn<String> photoPathsJson = GeneratedColumn<String>(
      'photo_paths_json', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('[]'));
  @override
  List<GeneratedColumn> get $columns => [
        id,
        deliveryId,
        customerId,
        customerCode,
        customerName,
        sequence,
        itemDescription,
        amount,
        paymentType,
        status,
        deliveredAt,
        failureReason,
        cashReceived,
        capturedLat,
        capturedLng,
        distanceMeters,
        verification,
        syncStatus,
        driverNote,
        soInvoiceNumber,
        doId,
        photoPathsJson
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'delivery_stops';
  @override
  VerificationContext validateIntegrity(Insertable<DeliveryStopsData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('delivery_id')) {
      context.handle(
          _deliveryIdMeta,
          deliveryId.isAcceptableOrUnknown(
              data['delivery_id']!, _deliveryIdMeta));
    } else if (isInserting) {
      context.missing(_deliveryIdMeta);
    }
    if (data.containsKey('customer_id')) {
      context.handle(
          _customerIdMeta,
          customerId.isAcceptableOrUnknown(
              data['customer_id']!, _customerIdMeta));
    } else if (isInserting) {
      context.missing(_customerIdMeta);
    }
    if (data.containsKey('customer_code')) {
      context.handle(
          _customerCodeMeta,
          customerCode.isAcceptableOrUnknown(
              data['customer_code']!, _customerCodeMeta));
    }
    if (data.containsKey('customer_name')) {
      context.handle(
          _customerNameMeta,
          customerName.isAcceptableOrUnknown(
              data['customer_name']!, _customerNameMeta));
    }
    if (data.containsKey('sequence')) {
      context.handle(_sequenceMeta,
          sequence.isAcceptableOrUnknown(data['sequence']!, _sequenceMeta));
    } else if (isInserting) {
      context.missing(_sequenceMeta);
    }
    if (data.containsKey('item_description')) {
      context.handle(
          _itemDescriptionMeta,
          itemDescription.isAcceptableOrUnknown(
              data['item_description']!, _itemDescriptionMeta));
    }
    if (data.containsKey('amount')) {
      context.handle(_amountMeta,
          amount.isAcceptableOrUnknown(data['amount']!, _amountMeta));
    }
    if (data.containsKey('payment_type')) {
      context.handle(
          _paymentTypeMeta,
          paymentType.isAcceptableOrUnknown(
              data['payment_type']!, _paymentTypeMeta));
    }
    if (data.containsKey('status')) {
      context.handle(_statusMeta,
          status.isAcceptableOrUnknown(data['status']!, _statusMeta));
    }
    if (data.containsKey('delivered_at')) {
      context.handle(
          _deliveredAtMeta,
          deliveredAt.isAcceptableOrUnknown(
              data['delivered_at']!, _deliveredAtMeta));
    }
    if (data.containsKey('failure_reason')) {
      context.handle(
          _failureReasonMeta,
          failureReason.isAcceptableOrUnknown(
              data['failure_reason']!, _failureReasonMeta));
    }
    if (data.containsKey('cash_received')) {
      context.handle(
          _cashReceivedMeta,
          cashReceived.isAcceptableOrUnknown(
              data['cash_received']!, _cashReceivedMeta));
    }
    if (data.containsKey('captured_lat')) {
      context.handle(
          _capturedLatMeta,
          capturedLat.isAcceptableOrUnknown(
              data['captured_lat']!, _capturedLatMeta));
    }
    if (data.containsKey('captured_lng')) {
      context.handle(
          _capturedLngMeta,
          capturedLng.isAcceptableOrUnknown(
              data['captured_lng']!, _capturedLngMeta));
    }
    if (data.containsKey('distance_meters')) {
      context.handle(
          _distanceMetersMeta,
          distanceMeters.isAcceptableOrUnknown(
              data['distance_meters']!, _distanceMetersMeta));
    }
    if (data.containsKey('verification')) {
      context.handle(
          _verificationMeta,
          verification.isAcceptableOrUnknown(
              data['verification']!, _verificationMeta));
    }
    if (data.containsKey('sync_status')) {
      context.handle(
          _syncStatusMeta,
          syncStatus.isAcceptableOrUnknown(
              data['sync_status']!, _syncStatusMeta));
    }
    if (data.containsKey('driver_note')) {
      context.handle(
          _driverNoteMeta,
          driverNote.isAcceptableOrUnknown(
              data['driver_note']!, _driverNoteMeta));
    }
    if (data.containsKey('so_invoice_number')) {
      context.handle(
          _soInvoiceNumberMeta,
          soInvoiceNumber.isAcceptableOrUnknown(
              data['so_invoice_number']!, _soInvoiceNumberMeta));
    }
    if (data.containsKey('do_id')) {
      context.handle(
          _doIdMeta, doId.isAcceptableOrUnknown(data['do_id']!, _doIdMeta));
    }
    if (data.containsKey('photo_paths_json')) {
      context.handle(
          _photoPathsJsonMeta,
          photoPathsJson.isAcceptableOrUnknown(
              data['photo_paths_json']!, _photoPathsJsonMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DeliveryStopsData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DeliveryStopsData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      deliveryId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}delivery_id'])!,
      customerId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}customer_id'])!,
      customerCode: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}customer_code'])!,
      customerName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}customer_name'])!,
      sequence: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}sequence'])!,
      itemDescription: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}item_description'])!,
      amount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}amount'])!,
      paymentType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}payment_type'])!,
      status: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}status'])!,
      deliveredAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}delivered_at']),
      failureReason: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}failure_reason']),
      cashReceived: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}cash_received']),
      capturedLat: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}captured_lat']),
      capturedLng: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}captured_lng']),
      distanceMeters: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}distance_meters']),
      verification: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}verification'])!,
      syncStatus: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_status'])!,
      driverNote: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}driver_note']),
      soInvoiceNumber: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}so_invoice_number']),
      doId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}do_id']),
      photoPathsJson: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}photo_paths_json'])!,
    );
  }

  @override
  $DeliveryStopsTable createAlias(String alias) {
    return $DeliveryStopsTable(attachedDatabase, alias);
  }
}

class DeliveryStopsData extends DataClass
    implements Insertable<DeliveryStopsData> {
  final String id;
  final String deliveryId;

  /// Snapshot fields so a delivery report stays meaningful even if
  /// the customer record is later edited.
  final String customerId;
  final String customerCode;
  final String customerName;
  final int sequence;
  final String itemDescription;

  /// Amount to be settled at this stop. Zero is valid (e.g. a free-of-
  /// charge drop). Uses int rupees to match the rest of the app's money.
  final int amount;

  /// 'cash' (driver collects physical money) or 'credit' (customer is
  /// on account, amount is logged as owed, nothing collected at drop).
  final String paymentType;
  final String status;
  final DateTime? deliveredAt;
  final String? failureReason;

  /// Actual cash the driver collected at the stop. Defaults to the
  /// dispatched [amount] when the driver marks delivered, but the
  /// driver can override if the customer short-paid. Null until a
  /// driver settles the stop; always null for credit stops.
  final int? cashReceived;

  /// Captured once the driver marks this stop done (6b). Nullable until
  /// then.
  final double? capturedLat;
  final double? capturedLng;

  /// Meters from the customer's saved location at the time of capture,
  /// computed the same way we compute visit distance.
  final int? distanceMeters;

  /// Geofence verification status, computed at mark-time against the
  /// org-wide [geofenceRadiusMeters] setting. Mirrors the salesperson
  /// visit-verification flow exactly — same customer locations, same
  /// radius, same three outcomes:
  ///   - 'pending'      : stop hasn't been marked yet
  ///   - 'verified'     : captured within the geofence
  ///   - 'outside'      : captured outside the geofence (driver can
  ///                      still mark delivered; this is a SOFT flag)
  ///   - 'no_location'  : no GPS fix available, or customer has no
  ///                      saved location
  /// Never blocks the driver — used for admin reporting and compliance
  /// pattern detection only.
  final String verification;

  /// Sync state for offline-marked stops. Local-only (not pushed to server).
  /// Mirrors visits.syncStatus.
  ///   'synced'  : on server (default for pulled rows)
  ///   'pending' : marked locally, not yet pushed
  final String syncStatus;

  /// Free-text instructions for the driver, set by accountant or
  /// dispatch. Nullable.
  final String? driverNote;

  /// Sales-order or invoice reference number. Nullable.
  final String? soInvoiceNumber;

  /// Source delivery order id when this stop was created from an approved
  /// DO (the dispatch DO-picking flow). Null for manually-created stops.
  final String? doId;

  /// Proof-of-delivery photos captured by the driver, stored as JSON
  /// array of absolute local file paths. Mirrors the pattern used by
  /// the salesperson visits table (photoPathsJson). The actual files
  /// live under the app's documents directory; uploads to Supabase
  /// are handled by the UploadWorker via the upload_queue table, so
  /// this column holds local paths even after upload completes.
  final String photoPathsJson;
  const DeliveryStopsData(
      {required this.id,
      required this.deliveryId,
      required this.customerId,
      required this.customerCode,
      required this.customerName,
      required this.sequence,
      required this.itemDescription,
      required this.amount,
      required this.paymentType,
      required this.status,
      this.deliveredAt,
      this.failureReason,
      this.cashReceived,
      this.capturedLat,
      this.capturedLng,
      this.distanceMeters,
      required this.verification,
      required this.syncStatus,
      this.driverNote,
      this.soInvoiceNumber,
      this.doId,
      required this.photoPathsJson});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['delivery_id'] = Variable<String>(deliveryId);
    map['customer_id'] = Variable<String>(customerId);
    map['customer_code'] = Variable<String>(customerCode);
    map['customer_name'] = Variable<String>(customerName);
    map['sequence'] = Variable<int>(sequence);
    map['item_description'] = Variable<String>(itemDescription);
    map['amount'] = Variable<int>(amount);
    map['payment_type'] = Variable<String>(paymentType);
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || deliveredAt != null) {
      map['delivered_at'] = Variable<DateTime>(deliveredAt);
    }
    if (!nullToAbsent || failureReason != null) {
      map['failure_reason'] = Variable<String>(failureReason);
    }
    if (!nullToAbsent || cashReceived != null) {
      map['cash_received'] = Variable<int>(cashReceived);
    }
    if (!nullToAbsent || capturedLat != null) {
      map['captured_lat'] = Variable<double>(capturedLat);
    }
    if (!nullToAbsent || capturedLng != null) {
      map['captured_lng'] = Variable<double>(capturedLng);
    }
    if (!nullToAbsent || distanceMeters != null) {
      map['distance_meters'] = Variable<int>(distanceMeters);
    }
    map['verification'] = Variable<String>(verification);
    map['sync_status'] = Variable<String>(syncStatus);
    if (!nullToAbsent || driverNote != null) {
      map['driver_note'] = Variable<String>(driverNote);
    }
    if (!nullToAbsent || soInvoiceNumber != null) {
      map['so_invoice_number'] = Variable<String>(soInvoiceNumber);
    }
    if (!nullToAbsent || doId != null) {
      map['do_id'] = Variable<String>(doId);
    }
    map['photo_paths_json'] = Variable<String>(photoPathsJson);
    return map;
  }

  DeliveryStopsCompanion toCompanion(bool nullToAbsent) {
    return DeliveryStopsCompanion(
      id: Value(id),
      deliveryId: Value(deliveryId),
      customerId: Value(customerId),
      customerCode: Value(customerCode),
      customerName: Value(customerName),
      sequence: Value(sequence),
      itemDescription: Value(itemDescription),
      amount: Value(amount),
      paymentType: Value(paymentType),
      status: Value(status),
      deliveredAt: deliveredAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deliveredAt),
      failureReason: failureReason == null && nullToAbsent
          ? const Value.absent()
          : Value(failureReason),
      cashReceived: cashReceived == null && nullToAbsent
          ? const Value.absent()
          : Value(cashReceived),
      capturedLat: capturedLat == null && nullToAbsent
          ? const Value.absent()
          : Value(capturedLat),
      capturedLng: capturedLng == null && nullToAbsent
          ? const Value.absent()
          : Value(capturedLng),
      distanceMeters: distanceMeters == null && nullToAbsent
          ? const Value.absent()
          : Value(distanceMeters),
      verification: Value(verification),
      syncStatus: Value(syncStatus),
      driverNote: driverNote == null && nullToAbsent
          ? const Value.absent()
          : Value(driverNote),
      soInvoiceNumber: soInvoiceNumber == null && nullToAbsent
          ? const Value.absent()
          : Value(soInvoiceNumber),
      doId: doId == null && nullToAbsent ? const Value.absent() : Value(doId),
      photoPathsJson: Value(photoPathsJson),
    );
  }

  factory DeliveryStopsData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DeliveryStopsData(
      id: serializer.fromJson<String>(json['id']),
      deliveryId: serializer.fromJson<String>(json['deliveryId']),
      customerId: serializer.fromJson<String>(json['customerId']),
      customerCode: serializer.fromJson<String>(json['customerCode']),
      customerName: serializer.fromJson<String>(json['customerName']),
      sequence: serializer.fromJson<int>(json['sequence']),
      itemDescription: serializer.fromJson<String>(json['itemDescription']),
      amount: serializer.fromJson<int>(json['amount']),
      paymentType: serializer.fromJson<String>(json['paymentType']),
      status: serializer.fromJson<String>(json['status']),
      deliveredAt: serializer.fromJson<DateTime?>(json['deliveredAt']),
      failureReason: serializer.fromJson<String?>(json['failureReason']),
      cashReceived: serializer.fromJson<int?>(json['cashReceived']),
      capturedLat: serializer.fromJson<double?>(json['capturedLat']),
      capturedLng: serializer.fromJson<double?>(json['capturedLng']),
      distanceMeters: serializer.fromJson<int?>(json['distanceMeters']),
      verification: serializer.fromJson<String>(json['verification']),
      syncStatus: serializer.fromJson<String>(json['syncStatus']),
      driverNote: serializer.fromJson<String?>(json['driverNote']),
      soInvoiceNumber: serializer.fromJson<String?>(json['soInvoiceNumber']),
      doId: serializer.fromJson<String?>(json['doId']),
      photoPathsJson: serializer.fromJson<String>(json['photoPathsJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'deliveryId': serializer.toJson<String>(deliveryId),
      'customerId': serializer.toJson<String>(customerId),
      'customerCode': serializer.toJson<String>(customerCode),
      'customerName': serializer.toJson<String>(customerName),
      'sequence': serializer.toJson<int>(sequence),
      'itemDescription': serializer.toJson<String>(itemDescription),
      'amount': serializer.toJson<int>(amount),
      'paymentType': serializer.toJson<String>(paymentType),
      'status': serializer.toJson<String>(status),
      'deliveredAt': serializer.toJson<DateTime?>(deliveredAt),
      'failureReason': serializer.toJson<String?>(failureReason),
      'cashReceived': serializer.toJson<int?>(cashReceived),
      'capturedLat': serializer.toJson<double?>(capturedLat),
      'capturedLng': serializer.toJson<double?>(capturedLng),
      'distanceMeters': serializer.toJson<int?>(distanceMeters),
      'verification': serializer.toJson<String>(verification),
      'syncStatus': serializer.toJson<String>(syncStatus),
      'driverNote': serializer.toJson<String?>(driverNote),
      'soInvoiceNumber': serializer.toJson<String?>(soInvoiceNumber),
      'doId': serializer.toJson<String?>(doId),
      'photoPathsJson': serializer.toJson<String>(photoPathsJson),
    };
  }

  DeliveryStopsData copyWith(
          {String? id,
          String? deliveryId,
          String? customerId,
          String? customerCode,
          String? customerName,
          int? sequence,
          String? itemDescription,
          int? amount,
          String? paymentType,
          String? status,
          Value<DateTime?> deliveredAt = const Value.absent(),
          Value<String?> failureReason = const Value.absent(),
          Value<int?> cashReceived = const Value.absent(),
          Value<double?> capturedLat = const Value.absent(),
          Value<double?> capturedLng = const Value.absent(),
          Value<int?> distanceMeters = const Value.absent(),
          String? verification,
          String? syncStatus,
          Value<String?> driverNote = const Value.absent(),
          Value<String?> soInvoiceNumber = const Value.absent(),
          Value<String?> doId = const Value.absent(),
          String? photoPathsJson}) =>
      DeliveryStopsData(
        id: id ?? this.id,
        deliveryId: deliveryId ?? this.deliveryId,
        customerId: customerId ?? this.customerId,
        customerCode: customerCode ?? this.customerCode,
        customerName: customerName ?? this.customerName,
        sequence: sequence ?? this.sequence,
        itemDescription: itemDescription ?? this.itemDescription,
        amount: amount ?? this.amount,
        paymentType: paymentType ?? this.paymentType,
        status: status ?? this.status,
        deliveredAt: deliveredAt.present ? deliveredAt.value : this.deliveredAt,
        failureReason:
            failureReason.present ? failureReason.value : this.failureReason,
        cashReceived:
            cashReceived.present ? cashReceived.value : this.cashReceived,
        capturedLat: capturedLat.present ? capturedLat.value : this.capturedLat,
        capturedLng: capturedLng.present ? capturedLng.value : this.capturedLng,
        distanceMeters:
            distanceMeters.present ? distanceMeters.value : this.distanceMeters,
        verification: verification ?? this.verification,
        syncStatus: syncStatus ?? this.syncStatus,
        driverNote: driverNote.present ? driverNote.value : this.driverNote,
        soInvoiceNumber: soInvoiceNumber.present
            ? soInvoiceNumber.value
            : this.soInvoiceNumber,
        doId: doId.present ? doId.value : this.doId,
        photoPathsJson: photoPathsJson ?? this.photoPathsJson,
      );
  DeliveryStopsData copyWithCompanion(DeliveryStopsCompanion data) {
    return DeliveryStopsData(
      id: data.id.present ? data.id.value : this.id,
      deliveryId:
          data.deliveryId.present ? data.deliveryId.value : this.deliveryId,
      customerId:
          data.customerId.present ? data.customerId.value : this.customerId,
      customerCode: data.customerCode.present
          ? data.customerCode.value
          : this.customerCode,
      customerName: data.customerName.present
          ? data.customerName.value
          : this.customerName,
      sequence: data.sequence.present ? data.sequence.value : this.sequence,
      itemDescription: data.itemDescription.present
          ? data.itemDescription.value
          : this.itemDescription,
      amount: data.amount.present ? data.amount.value : this.amount,
      paymentType:
          data.paymentType.present ? data.paymentType.value : this.paymentType,
      status: data.status.present ? data.status.value : this.status,
      deliveredAt:
          data.deliveredAt.present ? data.deliveredAt.value : this.deliveredAt,
      failureReason: data.failureReason.present
          ? data.failureReason.value
          : this.failureReason,
      cashReceived: data.cashReceived.present
          ? data.cashReceived.value
          : this.cashReceived,
      capturedLat:
          data.capturedLat.present ? data.capturedLat.value : this.capturedLat,
      capturedLng:
          data.capturedLng.present ? data.capturedLng.value : this.capturedLng,
      distanceMeters: data.distanceMeters.present
          ? data.distanceMeters.value
          : this.distanceMeters,
      verification: data.verification.present
          ? data.verification.value
          : this.verification,
      syncStatus:
          data.syncStatus.present ? data.syncStatus.value : this.syncStatus,
      driverNote:
          data.driverNote.present ? data.driverNote.value : this.driverNote,
      soInvoiceNumber: data.soInvoiceNumber.present
          ? data.soInvoiceNumber.value
          : this.soInvoiceNumber,
      doId: data.doId.present ? data.doId.value : this.doId,
      photoPathsJson: data.photoPathsJson.present
          ? data.photoPathsJson.value
          : this.photoPathsJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DeliveryStopsData(')
          ..write('id: $id, ')
          ..write('deliveryId: $deliveryId, ')
          ..write('customerId: $customerId, ')
          ..write('customerCode: $customerCode, ')
          ..write('customerName: $customerName, ')
          ..write('sequence: $sequence, ')
          ..write('itemDescription: $itemDescription, ')
          ..write('amount: $amount, ')
          ..write('paymentType: $paymentType, ')
          ..write('status: $status, ')
          ..write('deliveredAt: $deliveredAt, ')
          ..write('failureReason: $failureReason, ')
          ..write('cashReceived: $cashReceived, ')
          ..write('capturedLat: $capturedLat, ')
          ..write('capturedLng: $capturedLng, ')
          ..write('distanceMeters: $distanceMeters, ')
          ..write('verification: $verification, ')
          ..write('syncStatus: $syncStatus, ')
          ..write('driverNote: $driverNote, ')
          ..write('soInvoiceNumber: $soInvoiceNumber, ')
          ..write('doId: $doId, ')
          ..write('photoPathsJson: $photoPathsJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
        id,
        deliveryId,
        customerId,
        customerCode,
        customerName,
        sequence,
        itemDescription,
        amount,
        paymentType,
        status,
        deliveredAt,
        failureReason,
        cashReceived,
        capturedLat,
        capturedLng,
        distanceMeters,
        verification,
        syncStatus,
        driverNote,
        soInvoiceNumber,
        doId,
        photoPathsJson
      ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DeliveryStopsData &&
          other.id == this.id &&
          other.deliveryId == this.deliveryId &&
          other.customerId == this.customerId &&
          other.customerCode == this.customerCode &&
          other.customerName == this.customerName &&
          other.sequence == this.sequence &&
          other.itemDescription == this.itemDescription &&
          other.amount == this.amount &&
          other.paymentType == this.paymentType &&
          other.status == this.status &&
          other.deliveredAt == this.deliveredAt &&
          other.failureReason == this.failureReason &&
          other.cashReceived == this.cashReceived &&
          other.capturedLat == this.capturedLat &&
          other.capturedLng == this.capturedLng &&
          other.distanceMeters == this.distanceMeters &&
          other.verification == this.verification &&
          other.syncStatus == this.syncStatus &&
          other.driverNote == this.driverNote &&
          other.soInvoiceNumber == this.soInvoiceNumber &&
          other.doId == this.doId &&
          other.photoPathsJson == this.photoPathsJson);
}

class DeliveryStopsCompanion extends UpdateCompanion<DeliveryStopsData> {
  final Value<String> id;
  final Value<String> deliveryId;
  final Value<String> customerId;
  final Value<String> customerCode;
  final Value<String> customerName;
  final Value<int> sequence;
  final Value<String> itemDescription;
  final Value<int> amount;
  final Value<String> paymentType;
  final Value<String> status;
  final Value<DateTime?> deliveredAt;
  final Value<String?> failureReason;
  final Value<int?> cashReceived;
  final Value<double?> capturedLat;
  final Value<double?> capturedLng;
  final Value<int?> distanceMeters;
  final Value<String> verification;
  final Value<String> syncStatus;
  final Value<String?> driverNote;
  final Value<String?> soInvoiceNumber;
  final Value<String?> doId;
  final Value<String> photoPathsJson;
  final Value<int> rowid;
  const DeliveryStopsCompanion({
    this.id = const Value.absent(),
    this.deliveryId = const Value.absent(),
    this.customerId = const Value.absent(),
    this.customerCode = const Value.absent(),
    this.customerName = const Value.absent(),
    this.sequence = const Value.absent(),
    this.itemDescription = const Value.absent(),
    this.amount = const Value.absent(),
    this.paymentType = const Value.absent(),
    this.status = const Value.absent(),
    this.deliveredAt = const Value.absent(),
    this.failureReason = const Value.absent(),
    this.cashReceived = const Value.absent(),
    this.capturedLat = const Value.absent(),
    this.capturedLng = const Value.absent(),
    this.distanceMeters = const Value.absent(),
    this.verification = const Value.absent(),
    this.syncStatus = const Value.absent(),
    this.driverNote = const Value.absent(),
    this.soInvoiceNumber = const Value.absent(),
    this.doId = const Value.absent(),
    this.photoPathsJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DeliveryStopsCompanion.insert({
    required String id,
    required String deliveryId,
    required String customerId,
    this.customerCode = const Value.absent(),
    this.customerName = const Value.absent(),
    required int sequence,
    this.itemDescription = const Value.absent(),
    this.amount = const Value.absent(),
    this.paymentType = const Value.absent(),
    this.status = const Value.absent(),
    this.deliveredAt = const Value.absent(),
    this.failureReason = const Value.absent(),
    this.cashReceived = const Value.absent(),
    this.capturedLat = const Value.absent(),
    this.capturedLng = const Value.absent(),
    this.distanceMeters = const Value.absent(),
    this.verification = const Value.absent(),
    this.syncStatus = const Value.absent(),
    this.driverNote = const Value.absent(),
    this.soInvoiceNumber = const Value.absent(),
    this.doId = const Value.absent(),
    this.photoPathsJson = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        deliveryId = Value(deliveryId),
        customerId = Value(customerId),
        sequence = Value(sequence);
  static Insertable<DeliveryStopsData> custom({
    Expression<String>? id,
    Expression<String>? deliveryId,
    Expression<String>? customerId,
    Expression<String>? customerCode,
    Expression<String>? customerName,
    Expression<int>? sequence,
    Expression<String>? itemDescription,
    Expression<int>? amount,
    Expression<String>? paymentType,
    Expression<String>? status,
    Expression<DateTime>? deliveredAt,
    Expression<String>? failureReason,
    Expression<int>? cashReceived,
    Expression<double>? capturedLat,
    Expression<double>? capturedLng,
    Expression<int>? distanceMeters,
    Expression<String>? verification,
    Expression<String>? syncStatus,
    Expression<String>? driverNote,
    Expression<String>? soInvoiceNumber,
    Expression<String>? doId,
    Expression<String>? photoPathsJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (deliveryId != null) 'delivery_id': deliveryId,
      if (customerId != null) 'customer_id': customerId,
      if (customerCode != null) 'customer_code': customerCode,
      if (customerName != null) 'customer_name': customerName,
      if (sequence != null) 'sequence': sequence,
      if (itemDescription != null) 'item_description': itemDescription,
      if (amount != null) 'amount': amount,
      if (paymentType != null) 'payment_type': paymentType,
      if (status != null) 'status': status,
      if (deliveredAt != null) 'delivered_at': deliveredAt,
      if (failureReason != null) 'failure_reason': failureReason,
      if (cashReceived != null) 'cash_received': cashReceived,
      if (capturedLat != null) 'captured_lat': capturedLat,
      if (capturedLng != null) 'captured_lng': capturedLng,
      if (distanceMeters != null) 'distance_meters': distanceMeters,
      if (verification != null) 'verification': verification,
      if (syncStatus != null) 'sync_status': syncStatus,
      if (driverNote != null) 'driver_note': driverNote,
      if (soInvoiceNumber != null) 'so_invoice_number': soInvoiceNumber,
      if (doId != null) 'do_id': doId,
      if (photoPathsJson != null) 'photo_paths_json': photoPathsJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DeliveryStopsCompanion copyWith(
      {Value<String>? id,
      Value<String>? deliveryId,
      Value<String>? customerId,
      Value<String>? customerCode,
      Value<String>? customerName,
      Value<int>? sequence,
      Value<String>? itemDescription,
      Value<int>? amount,
      Value<String>? paymentType,
      Value<String>? status,
      Value<DateTime?>? deliveredAt,
      Value<String?>? failureReason,
      Value<int?>? cashReceived,
      Value<double?>? capturedLat,
      Value<double?>? capturedLng,
      Value<int?>? distanceMeters,
      Value<String>? verification,
      Value<String>? syncStatus,
      Value<String?>? driverNote,
      Value<String?>? soInvoiceNumber,
      Value<String?>? doId,
      Value<String>? photoPathsJson,
      Value<int>? rowid}) {
    return DeliveryStopsCompanion(
      id: id ?? this.id,
      deliveryId: deliveryId ?? this.deliveryId,
      customerId: customerId ?? this.customerId,
      customerCode: customerCode ?? this.customerCode,
      customerName: customerName ?? this.customerName,
      sequence: sequence ?? this.sequence,
      itemDescription: itemDescription ?? this.itemDescription,
      amount: amount ?? this.amount,
      paymentType: paymentType ?? this.paymentType,
      status: status ?? this.status,
      deliveredAt: deliveredAt ?? this.deliveredAt,
      failureReason: failureReason ?? this.failureReason,
      cashReceived: cashReceived ?? this.cashReceived,
      capturedLat: capturedLat ?? this.capturedLat,
      capturedLng: capturedLng ?? this.capturedLng,
      distanceMeters: distanceMeters ?? this.distanceMeters,
      verification: verification ?? this.verification,
      syncStatus: syncStatus ?? this.syncStatus,
      driverNote: driverNote ?? this.driverNote,
      soInvoiceNumber: soInvoiceNumber ?? this.soInvoiceNumber,
      doId: doId ?? this.doId,
      photoPathsJson: photoPathsJson ?? this.photoPathsJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (deliveryId.present) {
      map['delivery_id'] = Variable<String>(deliveryId.value);
    }
    if (customerId.present) {
      map['customer_id'] = Variable<String>(customerId.value);
    }
    if (customerCode.present) {
      map['customer_code'] = Variable<String>(customerCode.value);
    }
    if (customerName.present) {
      map['customer_name'] = Variable<String>(customerName.value);
    }
    if (sequence.present) {
      map['sequence'] = Variable<int>(sequence.value);
    }
    if (itemDescription.present) {
      map['item_description'] = Variable<String>(itemDescription.value);
    }
    if (amount.present) {
      map['amount'] = Variable<int>(amount.value);
    }
    if (paymentType.present) {
      map['payment_type'] = Variable<String>(paymentType.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (deliveredAt.present) {
      map['delivered_at'] = Variable<DateTime>(deliveredAt.value);
    }
    if (failureReason.present) {
      map['failure_reason'] = Variable<String>(failureReason.value);
    }
    if (cashReceived.present) {
      map['cash_received'] = Variable<int>(cashReceived.value);
    }
    if (capturedLat.present) {
      map['captured_lat'] = Variable<double>(capturedLat.value);
    }
    if (capturedLng.present) {
      map['captured_lng'] = Variable<double>(capturedLng.value);
    }
    if (distanceMeters.present) {
      map['distance_meters'] = Variable<int>(distanceMeters.value);
    }
    if (verification.present) {
      map['verification'] = Variable<String>(verification.value);
    }
    if (syncStatus.present) {
      map['sync_status'] = Variable<String>(syncStatus.value);
    }
    if (driverNote.present) {
      map['driver_note'] = Variable<String>(driverNote.value);
    }
    if (soInvoiceNumber.present) {
      map['so_invoice_number'] = Variable<String>(soInvoiceNumber.value);
    }
    if (doId.present) {
      map['do_id'] = Variable<String>(doId.value);
    }
    if (photoPathsJson.present) {
      map['photo_paths_json'] = Variable<String>(photoPathsJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DeliveryStopsCompanion(')
          ..write('id: $id, ')
          ..write('deliveryId: $deliveryId, ')
          ..write('customerId: $customerId, ')
          ..write('customerCode: $customerCode, ')
          ..write('customerName: $customerName, ')
          ..write('sequence: $sequence, ')
          ..write('itemDescription: $itemDescription, ')
          ..write('amount: $amount, ')
          ..write('paymentType: $paymentType, ')
          ..write('status: $status, ')
          ..write('deliveredAt: $deliveredAt, ')
          ..write('failureReason: $failureReason, ')
          ..write('cashReceived: $cashReceived, ')
          ..write('capturedLat: $capturedLat, ')
          ..write('capturedLng: $capturedLng, ')
          ..write('distanceMeters: $distanceMeters, ')
          ..write('verification: $verification, ')
          ..write('syncStatus: $syncStatus, ')
          ..write('driverNote: $driverNote, ')
          ..write('soInvoiceNumber: $soInvoiceNumber, ')
          ..write('doId: $doId, ')
          ..write('photoPathsJson: $photoPathsJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $OrgsTable extends Orgs with TableInfo<$OrgsTable, OrgsData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $OrgsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _masterAdminIdMeta =
      const VerificationMeta('masterAdminId');
  @override
  late final GeneratedColumn<String> masterAdminId = GeneratedColumn<String>(
      'master_admin_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _isActiveMeta =
      const VerificationMeta('isActive');
  @override
  late final GeneratedColumn<bool> isActive = GeneratedColumn<bool>(
      'is_active', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_active" IN (0, 1))'),
      defaultValue: const Constant(true));
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns =>
      [id, name, masterAdminId, isActive, createdAt, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'orgs';
  @override
  VerificationContext validateIntegrity(Insertable<OrgsData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('master_admin_id')) {
      context.handle(
          _masterAdminIdMeta,
          masterAdminId.isAcceptableOrUnknown(
              data['master_admin_id']!, _masterAdminIdMeta));
    }
    if (data.containsKey('is_active')) {
      context.handle(_isActiveMeta,
          isActive.isAcceptableOrUnknown(data['is_active']!, _isActiveMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  OrgsData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return OrgsData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      masterAdminId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}master_admin_id']),
      isActive: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_active'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at']),
    );
  }

  @override
  $OrgsTable createAlias(String alias) {
    return $OrgsTable(attachedDatabase, alias);
  }
}

class OrgsData extends DataClass implements Insertable<OrgsData> {
  final String id;
  final String name;

  /// The user (role=masterAdmin) responsible for this org. Nullable
  /// during the brief window between creating an org and assigning an
  /// admin, but in the happy path this is set at creation time.
  final String? masterAdminId;

  /// When false, users whose [orgId] matches this org cannot log in.
  /// Super admins are unaffected (no orgId).
  final bool isActive;
  final DateTime createdAt;
  final DateTime? updatedAt;
  const OrgsData(
      {required this.id,
      required this.name,
      this.masterAdminId,
      required this.isActive,
      required this.createdAt,
      this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || masterAdminId != null) {
      map['master_admin_id'] = Variable<String>(masterAdminId);
    }
    map['is_active'] = Variable<bool>(isActive);
    map['created_at'] = Variable<DateTime>(createdAt);
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    return map;
  }

  OrgsCompanion toCompanion(bool nullToAbsent) {
    return OrgsCompanion(
      id: Value(id),
      name: Value(name),
      masterAdminId: masterAdminId == null && nullToAbsent
          ? const Value.absent()
          : Value(masterAdminId),
      isActive: Value(isActive),
      createdAt: Value(createdAt),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
    );
  }

  factory OrgsData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return OrgsData(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      masterAdminId: serializer.fromJson<String?>(json['masterAdminId']),
      isActive: serializer.fromJson<bool>(json['isActive']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'masterAdminId': serializer.toJson<String?>(masterAdminId),
      'isActive': serializer.toJson<bool>(isActive),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
    };
  }

  OrgsData copyWith(
          {String? id,
          String? name,
          Value<String?> masterAdminId = const Value.absent(),
          bool? isActive,
          DateTime? createdAt,
          Value<DateTime?> updatedAt = const Value.absent()}) =>
      OrgsData(
        id: id ?? this.id,
        name: name ?? this.name,
        masterAdminId:
            masterAdminId.present ? masterAdminId.value : this.masterAdminId,
        isActive: isActive ?? this.isActive,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
      );
  OrgsData copyWithCompanion(OrgsCompanion data) {
    return OrgsData(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      masterAdminId: data.masterAdminId.present
          ? data.masterAdminId.value
          : this.masterAdminId,
      isActive: data.isActive.present ? data.isActive.value : this.isActive,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('OrgsData(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('masterAdminId: $masterAdminId, ')
          ..write('isActive: $isActive, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, name, masterAdminId, isActive, createdAt, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OrgsData &&
          other.id == this.id &&
          other.name == this.name &&
          other.masterAdminId == this.masterAdminId &&
          other.isActive == this.isActive &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class OrgsCompanion extends UpdateCompanion<OrgsData> {
  final Value<String> id;
  final Value<String> name;
  final Value<String?> masterAdminId;
  final Value<bool> isActive;
  final Value<DateTime> createdAt;
  final Value<DateTime?> updatedAt;
  final Value<int> rowid;
  const OrgsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.masterAdminId = const Value.absent(),
    this.isActive = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  OrgsCompanion.insert({
    required String id,
    required String name,
    this.masterAdminId = const Value.absent(),
    this.isActive = const Value.absent(),
    required DateTime createdAt,
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        name = Value(name),
        createdAt = Value(createdAt);
  static Insertable<OrgsData> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? masterAdminId,
    Expression<bool>? isActive,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (masterAdminId != null) 'master_admin_id': masterAdminId,
      if (isActive != null) 'is_active': isActive,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  OrgsCompanion copyWith(
      {Value<String>? id,
      Value<String>? name,
      Value<String?>? masterAdminId,
      Value<bool>? isActive,
      Value<DateTime>? createdAt,
      Value<DateTime?>? updatedAt,
      Value<int>? rowid}) {
    return OrgsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      masterAdminId: masterAdminId ?? this.masterAdminId,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (masterAdminId.present) {
      map['master_admin_id'] = Variable<String>(masterAdminId.value);
    }
    if (isActive.present) {
      map['is_active'] = Variable<bool>(isActive.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('OrgsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('masterAdminId: $masterAdminId, ')
          ..write('isActive: $isActive, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CompetitorCategoriesTable extends CompetitorCategories
    with TableInfo<$CompetitorCategoriesTable, CompetitorCategoryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CompetitorCategoriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _orgIdMeta = const VerificationMeta('orgId');
  @override
  late final GeneratedColumn<String> orgId = GeneratedColumn<String>(
      'org_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _positionMeta =
      const VerificationMeta('position');
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
      'position', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _isActiveMeta =
      const VerificationMeta('isActive');
  @override
  late final GeneratedColumn<bool> isActive = GeneratedColumn<bool>(
      'is_active', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_active" IN (0, 1))'),
      defaultValue: const Constant(true));
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, orgId, name, position, isActive, createdAt, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'competitor_categories';
  @override
  VerificationContext validateIntegrity(
      Insertable<CompetitorCategoryRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('org_id')) {
      context.handle(
          _orgIdMeta, orgId.isAcceptableOrUnknown(data['org_id']!, _orgIdMeta));
    } else if (isInserting) {
      context.missing(_orgIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('position')) {
      context.handle(_positionMeta,
          position.isAcceptableOrUnknown(data['position']!, _positionMeta));
    }
    if (data.containsKey('is_active')) {
      context.handle(_isActiveMeta,
          isActive.isAcceptableOrUnknown(data['is_active']!, _isActiveMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CompetitorCategoryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CompetitorCategoryRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      orgId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}org_id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      position: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}position'])!,
      isActive: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_active'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $CompetitorCategoriesTable createAlias(String alias) {
    return $CompetitorCategoriesTable(attachedDatabase, alias);
  }
}

class CompetitorCategoryRow extends DataClass
    implements Insertable<CompetitorCategoryRow> {
  final String id;
  final String orgId;
  final String name;
  final int position;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;
  const CompetitorCategoryRow(
      {required this.id,
      required this.orgId,
      required this.name,
      required this.position,
      required this.isActive,
      required this.createdAt,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['org_id'] = Variable<String>(orgId);
    map['name'] = Variable<String>(name);
    map['position'] = Variable<int>(position);
    map['is_active'] = Variable<bool>(isActive);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  CompetitorCategoriesCompanion toCompanion(bool nullToAbsent) {
    return CompetitorCategoriesCompanion(
      id: Value(id),
      orgId: Value(orgId),
      name: Value(name),
      position: Value(position),
      isActive: Value(isActive),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory CompetitorCategoryRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CompetitorCategoryRow(
      id: serializer.fromJson<String>(json['id']),
      orgId: serializer.fromJson<String>(json['orgId']),
      name: serializer.fromJson<String>(json['name']),
      position: serializer.fromJson<int>(json['position']),
      isActive: serializer.fromJson<bool>(json['isActive']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'orgId': serializer.toJson<String>(orgId),
      'name': serializer.toJson<String>(name),
      'position': serializer.toJson<int>(position),
      'isActive': serializer.toJson<bool>(isActive),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  CompetitorCategoryRow copyWith(
          {String? id,
          String? orgId,
          String? name,
          int? position,
          bool? isActive,
          DateTime? createdAt,
          DateTime? updatedAt}) =>
      CompetitorCategoryRow(
        id: id ?? this.id,
        orgId: orgId ?? this.orgId,
        name: name ?? this.name,
        position: position ?? this.position,
        isActive: isActive ?? this.isActive,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  CompetitorCategoryRow copyWithCompanion(CompetitorCategoriesCompanion data) {
    return CompetitorCategoryRow(
      id: data.id.present ? data.id.value : this.id,
      orgId: data.orgId.present ? data.orgId.value : this.orgId,
      name: data.name.present ? data.name.value : this.name,
      position: data.position.present ? data.position.value : this.position,
      isActive: data.isActive.present ? data.isActive.value : this.isActive,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CompetitorCategoryRow(')
          ..write('id: $id, ')
          ..write('orgId: $orgId, ')
          ..write('name: $name, ')
          ..write('position: $position, ')
          ..write('isActive: $isActive, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, orgId, name, position, isActive, createdAt, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CompetitorCategoryRow &&
          other.id == this.id &&
          other.orgId == this.orgId &&
          other.name == this.name &&
          other.position == this.position &&
          other.isActive == this.isActive &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class CompetitorCategoriesCompanion
    extends UpdateCompanion<CompetitorCategoryRow> {
  final Value<String> id;
  final Value<String> orgId;
  final Value<String> name;
  final Value<int> position;
  final Value<bool> isActive;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const CompetitorCategoriesCompanion({
    this.id = const Value.absent(),
    this.orgId = const Value.absent(),
    this.name = const Value.absent(),
    this.position = const Value.absent(),
    this.isActive = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CompetitorCategoriesCompanion.insert({
    required String id,
    required String orgId,
    required String name,
    this.position = const Value.absent(),
    this.isActive = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        orgId = Value(orgId),
        name = Value(name),
        createdAt = Value(createdAt),
        updatedAt = Value(updatedAt);
  static Insertable<CompetitorCategoryRow> custom({
    Expression<String>? id,
    Expression<String>? orgId,
    Expression<String>? name,
    Expression<int>? position,
    Expression<bool>? isActive,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (orgId != null) 'org_id': orgId,
      if (name != null) 'name': name,
      if (position != null) 'position': position,
      if (isActive != null) 'is_active': isActive,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CompetitorCategoriesCompanion copyWith(
      {Value<String>? id,
      Value<String>? orgId,
      Value<String>? name,
      Value<int>? position,
      Value<bool>? isActive,
      Value<DateTime>? createdAt,
      Value<DateTime>? updatedAt,
      Value<int>? rowid}) {
    return CompetitorCategoriesCompanion(
      id: id ?? this.id,
      orgId: orgId ?? this.orgId,
      name: name ?? this.name,
      position: position ?? this.position,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (orgId.present) {
      map['org_id'] = Variable<String>(orgId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (isActive.present) {
      map['is_active'] = Variable<bool>(isActive.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CompetitorCategoriesCompanion(')
          ..write('id: $id, ')
          ..write('orgId: $orgId, ')
          ..write('name: $name, ')
          ..write('position: $position, ')
          ..write('isActive: $isActive, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ProductsTable extends Products
    with TableInfo<$ProductsTable, ProductRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProductsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _orgIdMeta = const VerificationMeta('orgId');
  @override
  late final GeneratedColumn<String> orgId = GeneratedColumn<String>(
      'org_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _skuCodeMeta =
      const VerificationMeta('skuCode');
  @override
  late final GeneratedColumn<String> skuCode = GeneratedColumn<String>(
      'sku_code', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _positionMeta =
      const VerificationMeta('position');
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
      'position', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _isActiveMeta =
      const VerificationMeta('isActive');
  @override
  late final GeneratedColumn<bool> isActive = GeneratedColumn<bool>(
      'is_active', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_active" IN (0, 1))'),
      defaultValue: const Constant(true));
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, orgId, name, skuCode, position, isActive, createdAt, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'intelligence_products';
  @override
  VerificationContext validateIntegrity(Insertable<ProductRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('org_id')) {
      context.handle(
          _orgIdMeta, orgId.isAcceptableOrUnknown(data['org_id']!, _orgIdMeta));
    } else if (isInserting) {
      context.missing(_orgIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('sku_code')) {
      context.handle(_skuCodeMeta,
          skuCode.isAcceptableOrUnknown(data['sku_code']!, _skuCodeMeta));
    }
    if (data.containsKey('position')) {
      context.handle(_positionMeta,
          position.isAcceptableOrUnknown(data['position']!, _positionMeta));
    }
    if (data.containsKey('is_active')) {
      context.handle(_isActiveMeta,
          isActive.isAcceptableOrUnknown(data['is_active']!, _isActiveMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ProductRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ProductRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      orgId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}org_id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      skuCode: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sku_code']),
      position: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}position'])!,
      isActive: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_active'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $ProductsTable createAlias(String alias) {
    return $ProductsTable(attachedDatabase, alias);
  }
}

class ProductRow extends DataClass implements Insertable<ProductRow> {
  final String id;
  final String orgId;
  final String name;
  final String? skuCode;
  final int position;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;
  const ProductRow(
      {required this.id,
      required this.orgId,
      required this.name,
      this.skuCode,
      required this.position,
      required this.isActive,
      required this.createdAt,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['org_id'] = Variable<String>(orgId);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || skuCode != null) {
      map['sku_code'] = Variable<String>(skuCode);
    }
    map['position'] = Variable<int>(position);
    map['is_active'] = Variable<bool>(isActive);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  ProductsCompanion toCompanion(bool nullToAbsent) {
    return ProductsCompanion(
      id: Value(id),
      orgId: Value(orgId),
      name: Value(name),
      skuCode: skuCode == null && nullToAbsent
          ? const Value.absent()
          : Value(skuCode),
      position: Value(position),
      isActive: Value(isActive),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory ProductRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ProductRow(
      id: serializer.fromJson<String>(json['id']),
      orgId: serializer.fromJson<String>(json['orgId']),
      name: serializer.fromJson<String>(json['name']),
      skuCode: serializer.fromJson<String?>(json['skuCode']),
      position: serializer.fromJson<int>(json['position']),
      isActive: serializer.fromJson<bool>(json['isActive']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'orgId': serializer.toJson<String>(orgId),
      'name': serializer.toJson<String>(name),
      'skuCode': serializer.toJson<String?>(skuCode),
      'position': serializer.toJson<int>(position),
      'isActive': serializer.toJson<bool>(isActive),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  ProductRow copyWith(
          {String? id,
          String? orgId,
          String? name,
          Value<String?> skuCode = const Value.absent(),
          int? position,
          bool? isActive,
          DateTime? createdAt,
          DateTime? updatedAt}) =>
      ProductRow(
        id: id ?? this.id,
        orgId: orgId ?? this.orgId,
        name: name ?? this.name,
        skuCode: skuCode.present ? skuCode.value : this.skuCode,
        position: position ?? this.position,
        isActive: isActive ?? this.isActive,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  ProductRow copyWithCompanion(ProductsCompanion data) {
    return ProductRow(
      id: data.id.present ? data.id.value : this.id,
      orgId: data.orgId.present ? data.orgId.value : this.orgId,
      name: data.name.present ? data.name.value : this.name,
      skuCode: data.skuCode.present ? data.skuCode.value : this.skuCode,
      position: data.position.present ? data.position.value : this.position,
      isActive: data.isActive.present ? data.isActive.value : this.isActive,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ProductRow(')
          ..write('id: $id, ')
          ..write('orgId: $orgId, ')
          ..write('name: $name, ')
          ..write('skuCode: $skuCode, ')
          ..write('position: $position, ')
          ..write('isActive: $isActive, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, orgId, name, skuCode, position, isActive, createdAt, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ProductRow &&
          other.id == this.id &&
          other.orgId == this.orgId &&
          other.name == this.name &&
          other.skuCode == this.skuCode &&
          other.position == this.position &&
          other.isActive == this.isActive &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class ProductsCompanion extends UpdateCompanion<ProductRow> {
  final Value<String> id;
  final Value<String> orgId;
  final Value<String> name;
  final Value<String?> skuCode;
  final Value<int> position;
  final Value<bool> isActive;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const ProductsCompanion({
    this.id = const Value.absent(),
    this.orgId = const Value.absent(),
    this.name = const Value.absent(),
    this.skuCode = const Value.absent(),
    this.position = const Value.absent(),
    this.isActive = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ProductsCompanion.insert({
    required String id,
    required String orgId,
    required String name,
    this.skuCode = const Value.absent(),
    this.position = const Value.absent(),
    this.isActive = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        orgId = Value(orgId),
        name = Value(name),
        createdAt = Value(createdAt),
        updatedAt = Value(updatedAt);
  static Insertable<ProductRow> custom({
    Expression<String>? id,
    Expression<String>? orgId,
    Expression<String>? name,
    Expression<String>? skuCode,
    Expression<int>? position,
    Expression<bool>? isActive,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (orgId != null) 'org_id': orgId,
      if (name != null) 'name': name,
      if (skuCode != null) 'sku_code': skuCode,
      if (position != null) 'position': position,
      if (isActive != null) 'is_active': isActive,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ProductsCompanion copyWith(
      {Value<String>? id,
      Value<String>? orgId,
      Value<String>? name,
      Value<String?>? skuCode,
      Value<int>? position,
      Value<bool>? isActive,
      Value<DateTime>? createdAt,
      Value<DateTime>? updatedAt,
      Value<int>? rowid}) {
    return ProductsCompanion(
      id: id ?? this.id,
      orgId: orgId ?? this.orgId,
      name: name ?? this.name,
      skuCode: skuCode ?? this.skuCode,
      position: position ?? this.position,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (orgId.present) {
      map['org_id'] = Variable<String>(orgId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (skuCode.present) {
      map['sku_code'] = Variable<String>(skuCode.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (isActive.present) {
      map['is_active'] = Variable<bool>(isActive.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProductsCompanion(')
          ..write('id: $id, ')
          ..write('orgId: $orgId, ')
          ..write('name: $name, ')
          ..write('skuCode: $skuCode, ')
          ..write('position: $position, ')
          ..write('isActive: $isActive, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CompetitorSpottingsTable extends CompetitorSpottings
    with TableInfo<$CompetitorSpottingsTable, CompetitorSpottingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CompetitorSpottingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _orgIdMeta = const VerificationMeta('orgId');
  @override
  late final GeneratedColumn<String> orgId = GeneratedColumn<String>(
      'org_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _customerIdMeta =
      const VerificationMeta('customerId');
  @override
  late final GeneratedColumn<String> customerId = GeneratedColumn<String>(
      'customer_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _categoryIdMeta =
      const VerificationMeta('categoryId');
  @override
  late final GeneratedColumn<String> categoryId = GeneratedColumn<String>(
      'category_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _brandNameMeta =
      const VerificationMeta('brandName');
  @override
  late final GeneratedColumn<String> brandName = GeneratedColumn<String>(
      'brand_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _priceMeta = const VerificationMeta('price');
  @override
  late final GeneratedColumn<int> price = GeneratedColumn<int>(
      'price', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _specsMeta = const VerificationMeta('specs');
  @override
  late final GeneratedColumn<String> specs = GeneratedColumn<String>(
      'specs', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _surveyedByUserIdMeta =
      const VerificationMeta('surveyedByUserId');
  @override
  late final GeneratedColumn<String> surveyedByUserId = GeneratedColumn<String>(
      'surveyed_by_user_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _surveyedAtMeta =
      const VerificationMeta('surveyedAt');
  @override
  late final GeneratedColumn<DateTime> surveyedAt = GeneratedColumn<DateTime>(
      'surveyed_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _syncStatusMeta =
      const VerificationMeta('syncStatus');
  @override
  late final GeneratedColumn<String> syncStatus = GeneratedColumn<String>(
      'sync_status', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('synced'));
  @override
  List<GeneratedColumn> get $columns => [
        id,
        orgId,
        customerId,
        categoryId,
        brandName,
        price,
        specs,
        surveyedByUserId,
        surveyedAt,
        createdAt,
        syncStatus
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'competitor_spottings';
  @override
  VerificationContext validateIntegrity(
      Insertable<CompetitorSpottingRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('org_id')) {
      context.handle(
          _orgIdMeta, orgId.isAcceptableOrUnknown(data['org_id']!, _orgIdMeta));
    } else if (isInserting) {
      context.missing(_orgIdMeta);
    }
    if (data.containsKey('customer_id')) {
      context.handle(
          _customerIdMeta,
          customerId.isAcceptableOrUnknown(
              data['customer_id']!, _customerIdMeta));
    } else if (isInserting) {
      context.missing(_customerIdMeta);
    }
    if (data.containsKey('category_id')) {
      context.handle(
          _categoryIdMeta,
          categoryId.isAcceptableOrUnknown(
              data['category_id']!, _categoryIdMeta));
    } else if (isInserting) {
      context.missing(_categoryIdMeta);
    }
    if (data.containsKey('brand_name')) {
      context.handle(_brandNameMeta,
          brandName.isAcceptableOrUnknown(data['brand_name']!, _brandNameMeta));
    } else if (isInserting) {
      context.missing(_brandNameMeta);
    }
    if (data.containsKey('price')) {
      context.handle(
          _priceMeta, price.isAcceptableOrUnknown(data['price']!, _priceMeta));
    }
    if (data.containsKey('specs')) {
      context.handle(
          _specsMeta, specs.isAcceptableOrUnknown(data['specs']!, _specsMeta));
    }
    if (data.containsKey('surveyed_by_user_id')) {
      context.handle(
          _surveyedByUserIdMeta,
          surveyedByUserId.isAcceptableOrUnknown(
              data['surveyed_by_user_id']!, _surveyedByUserIdMeta));
    }
    if (data.containsKey('surveyed_at')) {
      context.handle(
          _surveyedAtMeta,
          surveyedAt.isAcceptableOrUnknown(
              data['surveyed_at']!, _surveyedAtMeta));
    } else if (isInserting) {
      context.missing(_surveyedAtMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('sync_status')) {
      context.handle(
          _syncStatusMeta,
          syncStatus.isAcceptableOrUnknown(
              data['sync_status']!, _syncStatusMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CompetitorSpottingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CompetitorSpottingRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      orgId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}org_id'])!,
      customerId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}customer_id'])!,
      categoryId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}category_id'])!,
      brandName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}brand_name'])!,
      price: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}price']),
      specs: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}specs']),
      surveyedByUserId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}surveyed_by_user_id']),
      surveyedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}surveyed_at'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      syncStatus: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_status'])!,
    );
  }

  @override
  $CompetitorSpottingsTable createAlias(String alias) {
    return $CompetitorSpottingsTable(attachedDatabase, alias);
  }
}

class CompetitorSpottingRow extends DataClass
    implements Insertable<CompetitorSpottingRow> {
  final String id;
  final String orgId;
  final String customerId;
  final String categoryId;
  final String brandName;
  final int? price;
  final String? specs;
  final String? surveyedByUserId;
  final DateTime surveyedAt;
  final DateTime createdAt;
  final String syncStatus;
  const CompetitorSpottingRow(
      {required this.id,
      required this.orgId,
      required this.customerId,
      required this.categoryId,
      required this.brandName,
      this.price,
      this.specs,
      this.surveyedByUserId,
      required this.surveyedAt,
      required this.createdAt,
      required this.syncStatus});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['org_id'] = Variable<String>(orgId);
    map['customer_id'] = Variable<String>(customerId);
    map['category_id'] = Variable<String>(categoryId);
    map['brand_name'] = Variable<String>(brandName);
    if (!nullToAbsent || price != null) {
      map['price'] = Variable<int>(price);
    }
    if (!nullToAbsent || specs != null) {
      map['specs'] = Variable<String>(specs);
    }
    if (!nullToAbsent || surveyedByUserId != null) {
      map['surveyed_by_user_id'] = Variable<String>(surveyedByUserId);
    }
    map['surveyed_at'] = Variable<DateTime>(surveyedAt);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['sync_status'] = Variable<String>(syncStatus);
    return map;
  }

  CompetitorSpottingsCompanion toCompanion(bool nullToAbsent) {
    return CompetitorSpottingsCompanion(
      id: Value(id),
      orgId: Value(orgId),
      customerId: Value(customerId),
      categoryId: Value(categoryId),
      brandName: Value(brandName),
      price:
          price == null && nullToAbsent ? const Value.absent() : Value(price),
      specs:
          specs == null && nullToAbsent ? const Value.absent() : Value(specs),
      surveyedByUserId: surveyedByUserId == null && nullToAbsent
          ? const Value.absent()
          : Value(surveyedByUserId),
      surveyedAt: Value(surveyedAt),
      createdAt: Value(createdAt),
      syncStatus: Value(syncStatus),
    );
  }

  factory CompetitorSpottingRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CompetitorSpottingRow(
      id: serializer.fromJson<String>(json['id']),
      orgId: serializer.fromJson<String>(json['orgId']),
      customerId: serializer.fromJson<String>(json['customerId']),
      categoryId: serializer.fromJson<String>(json['categoryId']),
      brandName: serializer.fromJson<String>(json['brandName']),
      price: serializer.fromJson<int?>(json['price']),
      specs: serializer.fromJson<String?>(json['specs']),
      surveyedByUserId: serializer.fromJson<String?>(json['surveyedByUserId']),
      surveyedAt: serializer.fromJson<DateTime>(json['surveyedAt']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      syncStatus: serializer.fromJson<String>(json['syncStatus']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'orgId': serializer.toJson<String>(orgId),
      'customerId': serializer.toJson<String>(customerId),
      'categoryId': serializer.toJson<String>(categoryId),
      'brandName': serializer.toJson<String>(brandName),
      'price': serializer.toJson<int?>(price),
      'specs': serializer.toJson<String?>(specs),
      'surveyedByUserId': serializer.toJson<String?>(surveyedByUserId),
      'surveyedAt': serializer.toJson<DateTime>(surveyedAt),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'syncStatus': serializer.toJson<String>(syncStatus),
    };
  }

  CompetitorSpottingRow copyWith(
          {String? id,
          String? orgId,
          String? customerId,
          String? categoryId,
          String? brandName,
          Value<int?> price = const Value.absent(),
          Value<String?> specs = const Value.absent(),
          Value<String?> surveyedByUserId = const Value.absent(),
          DateTime? surveyedAt,
          DateTime? createdAt,
          String? syncStatus}) =>
      CompetitorSpottingRow(
        id: id ?? this.id,
        orgId: orgId ?? this.orgId,
        customerId: customerId ?? this.customerId,
        categoryId: categoryId ?? this.categoryId,
        brandName: brandName ?? this.brandName,
        price: price.present ? price.value : this.price,
        specs: specs.present ? specs.value : this.specs,
        surveyedByUserId: surveyedByUserId.present
            ? surveyedByUserId.value
            : this.surveyedByUserId,
        surveyedAt: surveyedAt ?? this.surveyedAt,
        createdAt: createdAt ?? this.createdAt,
        syncStatus: syncStatus ?? this.syncStatus,
      );
  CompetitorSpottingRow copyWithCompanion(CompetitorSpottingsCompanion data) {
    return CompetitorSpottingRow(
      id: data.id.present ? data.id.value : this.id,
      orgId: data.orgId.present ? data.orgId.value : this.orgId,
      customerId:
          data.customerId.present ? data.customerId.value : this.customerId,
      categoryId:
          data.categoryId.present ? data.categoryId.value : this.categoryId,
      brandName: data.brandName.present ? data.brandName.value : this.brandName,
      price: data.price.present ? data.price.value : this.price,
      specs: data.specs.present ? data.specs.value : this.specs,
      surveyedByUserId: data.surveyedByUserId.present
          ? data.surveyedByUserId.value
          : this.surveyedByUserId,
      surveyedAt:
          data.surveyedAt.present ? data.surveyedAt.value : this.surveyedAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      syncStatus:
          data.syncStatus.present ? data.syncStatus.value : this.syncStatus,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CompetitorSpottingRow(')
          ..write('id: $id, ')
          ..write('orgId: $orgId, ')
          ..write('customerId: $customerId, ')
          ..write('categoryId: $categoryId, ')
          ..write('brandName: $brandName, ')
          ..write('price: $price, ')
          ..write('specs: $specs, ')
          ..write('surveyedByUserId: $surveyedByUserId, ')
          ..write('surveyedAt: $surveyedAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('syncStatus: $syncStatus')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, orgId, customerId, categoryId, brandName,
      price, specs, surveyedByUserId, surveyedAt, createdAt, syncStatus);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CompetitorSpottingRow &&
          other.id == this.id &&
          other.orgId == this.orgId &&
          other.customerId == this.customerId &&
          other.categoryId == this.categoryId &&
          other.brandName == this.brandName &&
          other.price == this.price &&
          other.specs == this.specs &&
          other.surveyedByUserId == this.surveyedByUserId &&
          other.surveyedAt == this.surveyedAt &&
          other.createdAt == this.createdAt &&
          other.syncStatus == this.syncStatus);
}

class CompetitorSpottingsCompanion
    extends UpdateCompanion<CompetitorSpottingRow> {
  final Value<String> id;
  final Value<String> orgId;
  final Value<String> customerId;
  final Value<String> categoryId;
  final Value<String> brandName;
  final Value<int?> price;
  final Value<String?> specs;
  final Value<String?> surveyedByUserId;
  final Value<DateTime> surveyedAt;
  final Value<DateTime> createdAt;
  final Value<String> syncStatus;
  final Value<int> rowid;
  const CompetitorSpottingsCompanion({
    this.id = const Value.absent(),
    this.orgId = const Value.absent(),
    this.customerId = const Value.absent(),
    this.categoryId = const Value.absent(),
    this.brandName = const Value.absent(),
    this.price = const Value.absent(),
    this.specs = const Value.absent(),
    this.surveyedByUserId = const Value.absent(),
    this.surveyedAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.syncStatus = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CompetitorSpottingsCompanion.insert({
    required String id,
    required String orgId,
    required String customerId,
    required String categoryId,
    required String brandName,
    this.price = const Value.absent(),
    this.specs = const Value.absent(),
    this.surveyedByUserId = const Value.absent(),
    required DateTime surveyedAt,
    required DateTime createdAt,
    this.syncStatus = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        orgId = Value(orgId),
        customerId = Value(customerId),
        categoryId = Value(categoryId),
        brandName = Value(brandName),
        surveyedAt = Value(surveyedAt),
        createdAt = Value(createdAt);
  static Insertable<CompetitorSpottingRow> custom({
    Expression<String>? id,
    Expression<String>? orgId,
    Expression<String>? customerId,
    Expression<String>? categoryId,
    Expression<String>? brandName,
    Expression<int>? price,
    Expression<String>? specs,
    Expression<String>? surveyedByUserId,
    Expression<DateTime>? surveyedAt,
    Expression<DateTime>? createdAt,
    Expression<String>? syncStatus,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (orgId != null) 'org_id': orgId,
      if (customerId != null) 'customer_id': customerId,
      if (categoryId != null) 'category_id': categoryId,
      if (brandName != null) 'brand_name': brandName,
      if (price != null) 'price': price,
      if (specs != null) 'specs': specs,
      if (surveyedByUserId != null) 'surveyed_by_user_id': surveyedByUserId,
      if (surveyedAt != null) 'surveyed_at': surveyedAt,
      if (createdAt != null) 'created_at': createdAt,
      if (syncStatus != null) 'sync_status': syncStatus,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CompetitorSpottingsCompanion copyWith(
      {Value<String>? id,
      Value<String>? orgId,
      Value<String>? customerId,
      Value<String>? categoryId,
      Value<String>? brandName,
      Value<int?>? price,
      Value<String?>? specs,
      Value<String?>? surveyedByUserId,
      Value<DateTime>? surveyedAt,
      Value<DateTime>? createdAt,
      Value<String>? syncStatus,
      Value<int>? rowid}) {
    return CompetitorSpottingsCompanion(
      id: id ?? this.id,
      orgId: orgId ?? this.orgId,
      customerId: customerId ?? this.customerId,
      categoryId: categoryId ?? this.categoryId,
      brandName: brandName ?? this.brandName,
      price: price ?? this.price,
      specs: specs ?? this.specs,
      surveyedByUserId: surveyedByUserId ?? this.surveyedByUserId,
      surveyedAt: surveyedAt ?? this.surveyedAt,
      createdAt: createdAt ?? this.createdAt,
      syncStatus: syncStatus ?? this.syncStatus,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (orgId.present) {
      map['org_id'] = Variable<String>(orgId.value);
    }
    if (customerId.present) {
      map['customer_id'] = Variable<String>(customerId.value);
    }
    if (categoryId.present) {
      map['category_id'] = Variable<String>(categoryId.value);
    }
    if (brandName.present) {
      map['brand_name'] = Variable<String>(brandName.value);
    }
    if (price.present) {
      map['price'] = Variable<int>(price.value);
    }
    if (specs.present) {
      map['specs'] = Variable<String>(specs.value);
    }
    if (surveyedByUserId.present) {
      map['surveyed_by_user_id'] = Variable<String>(surveyedByUserId.value);
    }
    if (surveyedAt.present) {
      map['surveyed_at'] = Variable<DateTime>(surveyedAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (syncStatus.present) {
      map['sync_status'] = Variable<String>(syncStatus.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CompetitorSpottingsCompanion(')
          ..write('id: $id, ')
          ..write('orgId: $orgId, ')
          ..write('customerId: $customerId, ')
          ..write('categoryId: $categoryId, ')
          ..write('brandName: $brandName, ')
          ..write('price: $price, ')
          ..write('specs: $specs, ')
          ..write('surveyedByUserId: $surveyedByUserId, ')
          ..write('surveyedAt: $surveyedAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('syncStatus: $syncStatus, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PlacementAuditsTable extends PlacementAudits
    with TableInfo<$PlacementAuditsTable, PlacementAuditRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlacementAuditsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _orgIdMeta = const VerificationMeta('orgId');
  @override
  late final GeneratedColumn<String> orgId = GeneratedColumn<String>(
      'org_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _customerIdMeta =
      const VerificationMeta('customerId');
  @override
  late final GeneratedColumn<String> customerId = GeneratedColumn<String>(
      'customer_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _productIdMeta =
      const VerificationMeta('productId');
  @override
  late final GeneratedColumn<String> productId = GeneratedColumn<String>(
      'product_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _isPresentMeta =
      const VerificationMeta('isPresent');
  @override
  late final GeneratedColumn<bool> isPresent = GeneratedColumn<bool>(
      'is_present', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_present" IN (0, 1))'));
  static const VerificationMeta _surveyedByUserIdMeta =
      const VerificationMeta('surveyedByUserId');
  @override
  late final GeneratedColumn<String> surveyedByUserId = GeneratedColumn<String>(
      'surveyed_by_user_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _surveyedAtMeta =
      const VerificationMeta('surveyedAt');
  @override
  late final GeneratedColumn<DateTime> surveyedAt = GeneratedColumn<DateTime>(
      'surveyed_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _syncStatusMeta =
      const VerificationMeta('syncStatus');
  @override
  late final GeneratedColumn<String> syncStatus = GeneratedColumn<String>(
      'sync_status', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('synced'));
  @override
  List<GeneratedColumn> get $columns => [
        id,
        orgId,
        customerId,
        productId,
        isPresent,
        surveyedByUserId,
        surveyedAt,
        createdAt,
        syncStatus
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'placement_audits';
  @override
  VerificationContext validateIntegrity(Insertable<PlacementAuditRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('org_id')) {
      context.handle(
          _orgIdMeta, orgId.isAcceptableOrUnknown(data['org_id']!, _orgIdMeta));
    } else if (isInserting) {
      context.missing(_orgIdMeta);
    }
    if (data.containsKey('customer_id')) {
      context.handle(
          _customerIdMeta,
          customerId.isAcceptableOrUnknown(
              data['customer_id']!, _customerIdMeta));
    } else if (isInserting) {
      context.missing(_customerIdMeta);
    }
    if (data.containsKey('product_id')) {
      context.handle(_productIdMeta,
          productId.isAcceptableOrUnknown(data['product_id']!, _productIdMeta));
    } else if (isInserting) {
      context.missing(_productIdMeta);
    }
    if (data.containsKey('is_present')) {
      context.handle(_isPresentMeta,
          isPresent.isAcceptableOrUnknown(data['is_present']!, _isPresentMeta));
    } else if (isInserting) {
      context.missing(_isPresentMeta);
    }
    if (data.containsKey('surveyed_by_user_id')) {
      context.handle(
          _surveyedByUserIdMeta,
          surveyedByUserId.isAcceptableOrUnknown(
              data['surveyed_by_user_id']!, _surveyedByUserIdMeta));
    }
    if (data.containsKey('surveyed_at')) {
      context.handle(
          _surveyedAtMeta,
          surveyedAt.isAcceptableOrUnknown(
              data['surveyed_at']!, _surveyedAtMeta));
    } else if (isInserting) {
      context.missing(_surveyedAtMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('sync_status')) {
      context.handle(
          _syncStatusMeta,
          syncStatus.isAcceptableOrUnknown(
              data['sync_status']!, _syncStatusMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PlacementAuditRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlacementAuditRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      orgId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}org_id'])!,
      customerId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}customer_id'])!,
      productId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}product_id'])!,
      isPresent: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_present'])!,
      surveyedByUserId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}surveyed_by_user_id']),
      surveyedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}surveyed_at'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      syncStatus: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_status'])!,
    );
  }

  @override
  $PlacementAuditsTable createAlias(String alias) {
    return $PlacementAuditsTable(attachedDatabase, alias);
  }
}

class PlacementAuditRow extends DataClass
    implements Insertable<PlacementAuditRow> {
  final String id;
  final String orgId;
  final String customerId;
  final String productId;
  final bool isPresent;
  final String? surveyedByUserId;
  final DateTime surveyedAt;
  final DateTime createdAt;
  final String syncStatus;
  const PlacementAuditRow(
      {required this.id,
      required this.orgId,
      required this.customerId,
      required this.productId,
      required this.isPresent,
      this.surveyedByUserId,
      required this.surveyedAt,
      required this.createdAt,
      required this.syncStatus});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['org_id'] = Variable<String>(orgId);
    map['customer_id'] = Variable<String>(customerId);
    map['product_id'] = Variable<String>(productId);
    map['is_present'] = Variable<bool>(isPresent);
    if (!nullToAbsent || surveyedByUserId != null) {
      map['surveyed_by_user_id'] = Variable<String>(surveyedByUserId);
    }
    map['surveyed_at'] = Variable<DateTime>(surveyedAt);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['sync_status'] = Variable<String>(syncStatus);
    return map;
  }

  PlacementAuditsCompanion toCompanion(bool nullToAbsent) {
    return PlacementAuditsCompanion(
      id: Value(id),
      orgId: Value(orgId),
      customerId: Value(customerId),
      productId: Value(productId),
      isPresent: Value(isPresent),
      surveyedByUserId: surveyedByUserId == null && nullToAbsent
          ? const Value.absent()
          : Value(surveyedByUserId),
      surveyedAt: Value(surveyedAt),
      createdAt: Value(createdAt),
      syncStatus: Value(syncStatus),
    );
  }

  factory PlacementAuditRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlacementAuditRow(
      id: serializer.fromJson<String>(json['id']),
      orgId: serializer.fromJson<String>(json['orgId']),
      customerId: serializer.fromJson<String>(json['customerId']),
      productId: serializer.fromJson<String>(json['productId']),
      isPresent: serializer.fromJson<bool>(json['isPresent']),
      surveyedByUserId: serializer.fromJson<String?>(json['surveyedByUserId']),
      surveyedAt: serializer.fromJson<DateTime>(json['surveyedAt']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      syncStatus: serializer.fromJson<String>(json['syncStatus']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'orgId': serializer.toJson<String>(orgId),
      'customerId': serializer.toJson<String>(customerId),
      'productId': serializer.toJson<String>(productId),
      'isPresent': serializer.toJson<bool>(isPresent),
      'surveyedByUserId': serializer.toJson<String?>(surveyedByUserId),
      'surveyedAt': serializer.toJson<DateTime>(surveyedAt),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'syncStatus': serializer.toJson<String>(syncStatus),
    };
  }

  PlacementAuditRow copyWith(
          {String? id,
          String? orgId,
          String? customerId,
          String? productId,
          bool? isPresent,
          Value<String?> surveyedByUserId = const Value.absent(),
          DateTime? surveyedAt,
          DateTime? createdAt,
          String? syncStatus}) =>
      PlacementAuditRow(
        id: id ?? this.id,
        orgId: orgId ?? this.orgId,
        customerId: customerId ?? this.customerId,
        productId: productId ?? this.productId,
        isPresent: isPresent ?? this.isPresent,
        surveyedByUserId: surveyedByUserId.present
            ? surveyedByUserId.value
            : this.surveyedByUserId,
        surveyedAt: surveyedAt ?? this.surveyedAt,
        createdAt: createdAt ?? this.createdAt,
        syncStatus: syncStatus ?? this.syncStatus,
      );
  PlacementAuditRow copyWithCompanion(PlacementAuditsCompanion data) {
    return PlacementAuditRow(
      id: data.id.present ? data.id.value : this.id,
      orgId: data.orgId.present ? data.orgId.value : this.orgId,
      customerId:
          data.customerId.present ? data.customerId.value : this.customerId,
      productId: data.productId.present ? data.productId.value : this.productId,
      isPresent: data.isPresent.present ? data.isPresent.value : this.isPresent,
      surveyedByUserId: data.surveyedByUserId.present
          ? data.surveyedByUserId.value
          : this.surveyedByUserId,
      surveyedAt:
          data.surveyedAt.present ? data.surveyedAt.value : this.surveyedAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      syncStatus:
          data.syncStatus.present ? data.syncStatus.value : this.syncStatus,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlacementAuditRow(')
          ..write('id: $id, ')
          ..write('orgId: $orgId, ')
          ..write('customerId: $customerId, ')
          ..write('productId: $productId, ')
          ..write('isPresent: $isPresent, ')
          ..write('surveyedByUserId: $surveyedByUserId, ')
          ..write('surveyedAt: $surveyedAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('syncStatus: $syncStatus')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, orgId, customerId, productId, isPresent,
      surveyedByUserId, surveyedAt, createdAt, syncStatus);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlacementAuditRow &&
          other.id == this.id &&
          other.orgId == this.orgId &&
          other.customerId == this.customerId &&
          other.productId == this.productId &&
          other.isPresent == this.isPresent &&
          other.surveyedByUserId == this.surveyedByUserId &&
          other.surveyedAt == this.surveyedAt &&
          other.createdAt == this.createdAt &&
          other.syncStatus == this.syncStatus);
}

class PlacementAuditsCompanion extends UpdateCompanion<PlacementAuditRow> {
  final Value<String> id;
  final Value<String> orgId;
  final Value<String> customerId;
  final Value<String> productId;
  final Value<bool> isPresent;
  final Value<String?> surveyedByUserId;
  final Value<DateTime> surveyedAt;
  final Value<DateTime> createdAt;
  final Value<String> syncStatus;
  final Value<int> rowid;
  const PlacementAuditsCompanion({
    this.id = const Value.absent(),
    this.orgId = const Value.absent(),
    this.customerId = const Value.absent(),
    this.productId = const Value.absent(),
    this.isPresent = const Value.absent(),
    this.surveyedByUserId = const Value.absent(),
    this.surveyedAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.syncStatus = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PlacementAuditsCompanion.insert({
    required String id,
    required String orgId,
    required String customerId,
    required String productId,
    required bool isPresent,
    this.surveyedByUserId = const Value.absent(),
    required DateTime surveyedAt,
    required DateTime createdAt,
    this.syncStatus = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        orgId = Value(orgId),
        customerId = Value(customerId),
        productId = Value(productId),
        isPresent = Value(isPresent),
        surveyedAt = Value(surveyedAt),
        createdAt = Value(createdAt);
  static Insertable<PlacementAuditRow> custom({
    Expression<String>? id,
    Expression<String>? orgId,
    Expression<String>? customerId,
    Expression<String>? productId,
    Expression<bool>? isPresent,
    Expression<String>? surveyedByUserId,
    Expression<DateTime>? surveyedAt,
    Expression<DateTime>? createdAt,
    Expression<String>? syncStatus,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (orgId != null) 'org_id': orgId,
      if (customerId != null) 'customer_id': customerId,
      if (productId != null) 'product_id': productId,
      if (isPresent != null) 'is_present': isPresent,
      if (surveyedByUserId != null) 'surveyed_by_user_id': surveyedByUserId,
      if (surveyedAt != null) 'surveyed_at': surveyedAt,
      if (createdAt != null) 'created_at': createdAt,
      if (syncStatus != null) 'sync_status': syncStatus,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PlacementAuditsCompanion copyWith(
      {Value<String>? id,
      Value<String>? orgId,
      Value<String>? customerId,
      Value<String>? productId,
      Value<bool>? isPresent,
      Value<String?>? surveyedByUserId,
      Value<DateTime>? surveyedAt,
      Value<DateTime>? createdAt,
      Value<String>? syncStatus,
      Value<int>? rowid}) {
    return PlacementAuditsCompanion(
      id: id ?? this.id,
      orgId: orgId ?? this.orgId,
      customerId: customerId ?? this.customerId,
      productId: productId ?? this.productId,
      isPresent: isPresent ?? this.isPresent,
      surveyedByUserId: surveyedByUserId ?? this.surveyedByUserId,
      surveyedAt: surveyedAt ?? this.surveyedAt,
      createdAt: createdAt ?? this.createdAt,
      syncStatus: syncStatus ?? this.syncStatus,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (orgId.present) {
      map['org_id'] = Variable<String>(orgId.value);
    }
    if (customerId.present) {
      map['customer_id'] = Variable<String>(customerId.value);
    }
    if (productId.present) {
      map['product_id'] = Variable<String>(productId.value);
    }
    if (isPresent.present) {
      map['is_present'] = Variable<bool>(isPresent.value);
    }
    if (surveyedByUserId.present) {
      map['surveyed_by_user_id'] = Variable<String>(surveyedByUserId.value);
    }
    if (surveyedAt.present) {
      map['surveyed_at'] = Variable<DateTime>(surveyedAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (syncStatus.present) {
      map['sync_status'] = Variable<String>(syncStatus.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlacementAuditsCompanion(')
          ..write('id: $id, ')
          ..write('orgId: $orgId, ')
          ..write('customerId: $customerId, ')
          ..write('productId: $productId, ')
          ..write('isPresent: $isPresent, ')
          ..write('surveyedByUserId: $surveyedByUserId, ')
          ..write('surveyedAt: $surveyedAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('syncStatus: $syncStatus, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CatalogProductsTable extends CatalogProducts
    with TableInfo<$CatalogProductsTable, CatalogProductRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CatalogProductsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _orgIdMeta = const VerificationMeta('orgId');
  @override
  late final GeneratedColumn<String> orgId = GeneratedColumn<String>(
      'org_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _skuMeta = const VerificationMeta('sku');
  @override
  late final GeneratedColumn<String> sku = GeneratedColumn<String>(
      'sku', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _sellingPriceMeta =
      const VerificationMeta('sellingPrice');
  @override
  late final GeneratedColumn<double> sellingPrice = GeneratedColumn<double>(
      'selling_price', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _baseUomIdMeta =
      const VerificationMeta('baseUomId');
  @override
  late final GeneratedColumn<String> baseUomId = GeneratedColumn<String>(
      'base_uom_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _productSubGroupMeta =
      const VerificationMeta('productSubGroup');
  @override
  late final GeneratedColumn<String> productSubGroup = GeneratedColumn<String>(
      'product_sub_group', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _isActiveMeta =
      const VerificationMeta('isActive');
  @override
  late final GeneratedColumn<bool> isActive = GeneratedColumn<bool>(
      'is_active', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_active" IN (0, 1))'),
      defaultValue: const Constant(true));
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _syncStatusMeta =
      const VerificationMeta('syncStatus');
  @override
  late final GeneratedColumn<String> syncStatus = GeneratedColumn<String>(
      'sync_status', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('synced'));
  @override
  List<GeneratedColumn> get $columns => [
        id,
        orgId,
        name,
        sku,
        sellingPrice,
        baseUomId,
        productSubGroup,
        isActive,
        updatedAt,
        syncStatus
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'catalog_products';
  @override
  VerificationContext validateIntegrity(Insertable<CatalogProductRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('org_id')) {
      context.handle(
          _orgIdMeta, orgId.isAcceptableOrUnknown(data['org_id']!, _orgIdMeta));
    } else if (isInserting) {
      context.missing(_orgIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('sku')) {
      context.handle(
          _skuMeta, sku.isAcceptableOrUnknown(data['sku']!, _skuMeta));
    }
    if (data.containsKey('selling_price')) {
      context.handle(
          _sellingPriceMeta,
          sellingPrice.isAcceptableOrUnknown(
              data['selling_price']!, _sellingPriceMeta));
    }
    if (data.containsKey('base_uom_id')) {
      context.handle(
          _baseUomIdMeta,
          baseUomId.isAcceptableOrUnknown(
              data['base_uom_id']!, _baseUomIdMeta));
    }
    if (data.containsKey('product_sub_group')) {
      context.handle(
          _productSubGroupMeta,
          productSubGroup.isAcceptableOrUnknown(
              data['product_sub_group']!, _productSubGroupMeta));
    }
    if (data.containsKey('is_active')) {
      context.handle(_isActiveMeta,
          isActive.isAcceptableOrUnknown(data['is_active']!, _isActiveMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    if (data.containsKey('sync_status')) {
      context.handle(
          _syncStatusMeta,
          syncStatus.isAcceptableOrUnknown(
              data['sync_status']!, _syncStatusMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CatalogProductRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CatalogProductRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      orgId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}org_id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      sku: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sku']),
      sellingPrice: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}selling_price'])!,
      baseUomId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}base_uom_id']),
      productSubGroup: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}product_sub_group']),
      isActive: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_active'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at']),
      syncStatus: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_status'])!,
    );
  }

  @override
  $CatalogProductsTable createAlias(String alias) {
    return $CatalogProductsTable(attachedDatabase, alias);
  }
}

class CatalogProductRow extends DataClass
    implements Insertable<CatalogProductRow> {
  final String id;
  final String orgId;
  final String name;
  final String? sku;
  final double sellingPrice;
  final String? baseUomId;
  final String? productSubGroup;
  final bool isActive;
  final DateTime? updatedAt;
  final String syncStatus;
  const CatalogProductRow(
      {required this.id,
      required this.orgId,
      required this.name,
      this.sku,
      required this.sellingPrice,
      this.baseUomId,
      this.productSubGroup,
      required this.isActive,
      this.updatedAt,
      required this.syncStatus});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['org_id'] = Variable<String>(orgId);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || sku != null) {
      map['sku'] = Variable<String>(sku);
    }
    map['selling_price'] = Variable<double>(sellingPrice);
    if (!nullToAbsent || baseUomId != null) {
      map['base_uom_id'] = Variable<String>(baseUomId);
    }
    if (!nullToAbsent || productSubGroup != null) {
      map['product_sub_group'] = Variable<String>(productSubGroup);
    }
    map['is_active'] = Variable<bool>(isActive);
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    map['sync_status'] = Variable<String>(syncStatus);
    return map;
  }

  CatalogProductsCompanion toCompanion(bool nullToAbsent) {
    return CatalogProductsCompanion(
      id: Value(id),
      orgId: Value(orgId),
      name: Value(name),
      sku: sku == null && nullToAbsent ? const Value.absent() : Value(sku),
      sellingPrice: Value(sellingPrice),
      baseUomId: baseUomId == null && nullToAbsent
          ? const Value.absent()
          : Value(baseUomId),
      productSubGroup: productSubGroup == null && nullToAbsent
          ? const Value.absent()
          : Value(productSubGroup),
      isActive: Value(isActive),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
      syncStatus: Value(syncStatus),
    );
  }

  factory CatalogProductRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CatalogProductRow(
      id: serializer.fromJson<String>(json['id']),
      orgId: serializer.fromJson<String>(json['orgId']),
      name: serializer.fromJson<String>(json['name']),
      sku: serializer.fromJson<String?>(json['sku']),
      sellingPrice: serializer.fromJson<double>(json['sellingPrice']),
      baseUomId: serializer.fromJson<String?>(json['baseUomId']),
      productSubGroup: serializer.fromJson<String?>(json['productSubGroup']),
      isActive: serializer.fromJson<bool>(json['isActive']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
      syncStatus: serializer.fromJson<String>(json['syncStatus']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'orgId': serializer.toJson<String>(orgId),
      'name': serializer.toJson<String>(name),
      'sku': serializer.toJson<String?>(sku),
      'sellingPrice': serializer.toJson<double>(sellingPrice),
      'baseUomId': serializer.toJson<String?>(baseUomId),
      'productSubGroup': serializer.toJson<String?>(productSubGroup),
      'isActive': serializer.toJson<bool>(isActive),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
      'syncStatus': serializer.toJson<String>(syncStatus),
    };
  }

  CatalogProductRow copyWith(
          {String? id,
          String? orgId,
          String? name,
          Value<String?> sku = const Value.absent(),
          double? sellingPrice,
          Value<String?> baseUomId = const Value.absent(),
          Value<String?> productSubGroup = const Value.absent(),
          bool? isActive,
          Value<DateTime?> updatedAt = const Value.absent(),
          String? syncStatus}) =>
      CatalogProductRow(
        id: id ?? this.id,
        orgId: orgId ?? this.orgId,
        name: name ?? this.name,
        sku: sku.present ? sku.value : this.sku,
        sellingPrice: sellingPrice ?? this.sellingPrice,
        baseUomId: baseUomId.present ? baseUomId.value : this.baseUomId,
        productSubGroup: productSubGroup.present
            ? productSubGroup.value
            : this.productSubGroup,
        isActive: isActive ?? this.isActive,
        updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
        syncStatus: syncStatus ?? this.syncStatus,
      );
  CatalogProductRow copyWithCompanion(CatalogProductsCompanion data) {
    return CatalogProductRow(
      id: data.id.present ? data.id.value : this.id,
      orgId: data.orgId.present ? data.orgId.value : this.orgId,
      name: data.name.present ? data.name.value : this.name,
      sku: data.sku.present ? data.sku.value : this.sku,
      sellingPrice: data.sellingPrice.present
          ? data.sellingPrice.value
          : this.sellingPrice,
      baseUomId: data.baseUomId.present ? data.baseUomId.value : this.baseUomId,
      productSubGroup: data.productSubGroup.present
          ? data.productSubGroup.value
          : this.productSubGroup,
      isActive: data.isActive.present ? data.isActive.value : this.isActive,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      syncStatus:
          data.syncStatus.present ? data.syncStatus.value : this.syncStatus,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CatalogProductRow(')
          ..write('id: $id, ')
          ..write('orgId: $orgId, ')
          ..write('name: $name, ')
          ..write('sku: $sku, ')
          ..write('sellingPrice: $sellingPrice, ')
          ..write('baseUomId: $baseUomId, ')
          ..write('productSubGroup: $productSubGroup, ')
          ..write('isActive: $isActive, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('syncStatus: $syncStatus')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, orgId, name, sku, sellingPrice, baseUomId,
      productSubGroup, isActive, updatedAt, syncStatus);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CatalogProductRow &&
          other.id == this.id &&
          other.orgId == this.orgId &&
          other.name == this.name &&
          other.sku == this.sku &&
          other.sellingPrice == this.sellingPrice &&
          other.baseUomId == this.baseUomId &&
          other.productSubGroup == this.productSubGroup &&
          other.isActive == this.isActive &&
          other.updatedAt == this.updatedAt &&
          other.syncStatus == this.syncStatus);
}

class CatalogProductsCompanion extends UpdateCompanion<CatalogProductRow> {
  final Value<String> id;
  final Value<String> orgId;
  final Value<String> name;
  final Value<String?> sku;
  final Value<double> sellingPrice;
  final Value<String?> baseUomId;
  final Value<String?> productSubGroup;
  final Value<bool> isActive;
  final Value<DateTime?> updatedAt;
  final Value<String> syncStatus;
  final Value<int> rowid;
  const CatalogProductsCompanion({
    this.id = const Value.absent(),
    this.orgId = const Value.absent(),
    this.name = const Value.absent(),
    this.sku = const Value.absent(),
    this.sellingPrice = const Value.absent(),
    this.baseUomId = const Value.absent(),
    this.productSubGroup = const Value.absent(),
    this.isActive = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.syncStatus = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CatalogProductsCompanion.insert({
    required String id,
    required String orgId,
    required String name,
    this.sku = const Value.absent(),
    this.sellingPrice = const Value.absent(),
    this.baseUomId = const Value.absent(),
    this.productSubGroup = const Value.absent(),
    this.isActive = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.syncStatus = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        orgId = Value(orgId),
        name = Value(name);
  static Insertable<CatalogProductRow> custom({
    Expression<String>? id,
    Expression<String>? orgId,
    Expression<String>? name,
    Expression<String>? sku,
    Expression<double>? sellingPrice,
    Expression<String>? baseUomId,
    Expression<String>? productSubGroup,
    Expression<bool>? isActive,
    Expression<DateTime>? updatedAt,
    Expression<String>? syncStatus,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (orgId != null) 'org_id': orgId,
      if (name != null) 'name': name,
      if (sku != null) 'sku': sku,
      if (sellingPrice != null) 'selling_price': sellingPrice,
      if (baseUomId != null) 'base_uom_id': baseUomId,
      if (productSubGroup != null) 'product_sub_group': productSubGroup,
      if (isActive != null) 'is_active': isActive,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (syncStatus != null) 'sync_status': syncStatus,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CatalogProductsCompanion copyWith(
      {Value<String>? id,
      Value<String>? orgId,
      Value<String>? name,
      Value<String?>? sku,
      Value<double>? sellingPrice,
      Value<String?>? baseUomId,
      Value<String?>? productSubGroup,
      Value<bool>? isActive,
      Value<DateTime?>? updatedAt,
      Value<String>? syncStatus,
      Value<int>? rowid}) {
    return CatalogProductsCompanion(
      id: id ?? this.id,
      orgId: orgId ?? this.orgId,
      name: name ?? this.name,
      sku: sku ?? this.sku,
      sellingPrice: sellingPrice ?? this.sellingPrice,
      baseUomId: baseUomId ?? this.baseUomId,
      productSubGroup: productSubGroup ?? this.productSubGroup,
      isActive: isActive ?? this.isActive,
      updatedAt: updatedAt ?? this.updatedAt,
      syncStatus: syncStatus ?? this.syncStatus,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (orgId.present) {
      map['org_id'] = Variable<String>(orgId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (sku.present) {
      map['sku'] = Variable<String>(sku.value);
    }
    if (sellingPrice.present) {
      map['selling_price'] = Variable<double>(sellingPrice.value);
    }
    if (baseUomId.present) {
      map['base_uom_id'] = Variable<String>(baseUomId.value);
    }
    if (productSubGroup.present) {
      map['product_sub_group'] = Variable<String>(productSubGroup.value);
    }
    if (isActive.present) {
      map['is_active'] = Variable<bool>(isActive.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (syncStatus.present) {
      map['sync_status'] = Variable<String>(syncStatus.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CatalogProductsCompanion(')
          ..write('id: $id, ')
          ..write('orgId: $orgId, ')
          ..write('name: $name, ')
          ..write('sku: $sku, ')
          ..write('sellingPrice: $sellingPrice, ')
          ..write('baseUomId: $baseUomId, ')
          ..write('productSubGroup: $productSubGroup, ')
          ..write('isActive: $isActive, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('syncStatus: $syncStatus, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $FieldOrdersTable extends FieldOrders
    with TableInfo<$FieldOrdersTable, FieldOrderRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FieldOrdersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _orgIdMeta = const VerificationMeta('orgId');
  @override
  late final GeneratedColumn<String> orgId = GeneratedColumn<String>(
      'org_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _customerIdMeta =
      const VerificationMeta('customerId');
  @override
  late final GeneratedColumn<String> customerId = GeneratedColumn<String>(
      'customer_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _salespersonIdMeta =
      const VerificationMeta('salespersonId');
  @override
  late final GeneratedColumn<String> salespersonId = GeneratedColumn<String>(
      'salesperson_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
      'status', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('submitted'));
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
      'notes', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _syncStatusMeta =
      const VerificationMeta('syncStatus');
  @override
  late final GeneratedColumn<String> syncStatus = GeneratedColumn<String>(
      'sync_status', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('pending'));
  @override
  List<GeneratedColumn> get $columns => [
        id,
        orgId,
        customerId,
        salespersonId,
        status,
        notes,
        createdAt,
        syncStatus
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'field_orders';
  @override
  VerificationContext validateIntegrity(Insertable<FieldOrderRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('org_id')) {
      context.handle(
          _orgIdMeta, orgId.isAcceptableOrUnknown(data['org_id']!, _orgIdMeta));
    } else if (isInserting) {
      context.missing(_orgIdMeta);
    }
    if (data.containsKey('customer_id')) {
      context.handle(
          _customerIdMeta,
          customerId.isAcceptableOrUnknown(
              data['customer_id']!, _customerIdMeta));
    } else if (isInserting) {
      context.missing(_customerIdMeta);
    }
    if (data.containsKey('salesperson_id')) {
      context.handle(
          _salespersonIdMeta,
          salespersonId.isAcceptableOrUnknown(
              data['salesperson_id']!, _salespersonIdMeta));
    } else if (isInserting) {
      context.missing(_salespersonIdMeta);
    }
    if (data.containsKey('status')) {
      context.handle(_statusMeta,
          status.isAcceptableOrUnknown(data['status']!, _statusMeta));
    }
    if (data.containsKey('notes')) {
      context.handle(
          _notesMeta, notes.isAcceptableOrUnknown(data['notes']!, _notesMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('sync_status')) {
      context.handle(
          _syncStatusMeta,
          syncStatus.isAcceptableOrUnknown(
              data['sync_status']!, _syncStatusMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  FieldOrderRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return FieldOrderRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      orgId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}org_id'])!,
      customerId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}customer_id'])!,
      salespersonId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}salesperson_id'])!,
      status: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}status'])!,
      notes: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}notes']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      syncStatus: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_status'])!,
    );
  }

  @override
  $FieldOrdersTable createAlias(String alias) {
    return $FieldOrdersTable(attachedDatabase, alias);
  }
}

class FieldOrderRow extends DataClass implements Insertable<FieldOrderRow> {
  final String id;
  final String orgId;
  final String customerId;
  final String salespersonId;
  final String status;
  final String? notes;
  final DateTime createdAt;
  final String syncStatus;
  const FieldOrderRow(
      {required this.id,
      required this.orgId,
      required this.customerId,
      required this.salespersonId,
      required this.status,
      this.notes,
      required this.createdAt,
      required this.syncStatus});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['org_id'] = Variable<String>(orgId);
    map['customer_id'] = Variable<String>(customerId);
    map['salesperson_id'] = Variable<String>(salespersonId);
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || notes != null) {
      map['notes'] = Variable<String>(notes);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['sync_status'] = Variable<String>(syncStatus);
    return map;
  }

  FieldOrdersCompanion toCompanion(bool nullToAbsent) {
    return FieldOrdersCompanion(
      id: Value(id),
      orgId: Value(orgId),
      customerId: Value(customerId),
      salespersonId: Value(salespersonId),
      status: Value(status),
      notes:
          notes == null && nullToAbsent ? const Value.absent() : Value(notes),
      createdAt: Value(createdAt),
      syncStatus: Value(syncStatus),
    );
  }

  factory FieldOrderRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return FieldOrderRow(
      id: serializer.fromJson<String>(json['id']),
      orgId: serializer.fromJson<String>(json['orgId']),
      customerId: serializer.fromJson<String>(json['customerId']),
      salespersonId: serializer.fromJson<String>(json['salespersonId']),
      status: serializer.fromJson<String>(json['status']),
      notes: serializer.fromJson<String?>(json['notes']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      syncStatus: serializer.fromJson<String>(json['syncStatus']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'orgId': serializer.toJson<String>(orgId),
      'customerId': serializer.toJson<String>(customerId),
      'salespersonId': serializer.toJson<String>(salespersonId),
      'status': serializer.toJson<String>(status),
      'notes': serializer.toJson<String?>(notes),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'syncStatus': serializer.toJson<String>(syncStatus),
    };
  }

  FieldOrderRow copyWith(
          {String? id,
          String? orgId,
          String? customerId,
          String? salespersonId,
          String? status,
          Value<String?> notes = const Value.absent(),
          DateTime? createdAt,
          String? syncStatus}) =>
      FieldOrderRow(
        id: id ?? this.id,
        orgId: orgId ?? this.orgId,
        customerId: customerId ?? this.customerId,
        salespersonId: salespersonId ?? this.salespersonId,
        status: status ?? this.status,
        notes: notes.present ? notes.value : this.notes,
        createdAt: createdAt ?? this.createdAt,
        syncStatus: syncStatus ?? this.syncStatus,
      );
  FieldOrderRow copyWithCompanion(FieldOrdersCompanion data) {
    return FieldOrderRow(
      id: data.id.present ? data.id.value : this.id,
      orgId: data.orgId.present ? data.orgId.value : this.orgId,
      customerId:
          data.customerId.present ? data.customerId.value : this.customerId,
      salespersonId: data.salespersonId.present
          ? data.salespersonId.value
          : this.salespersonId,
      status: data.status.present ? data.status.value : this.status,
      notes: data.notes.present ? data.notes.value : this.notes,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      syncStatus:
          data.syncStatus.present ? data.syncStatus.value : this.syncStatus,
    );
  }

  @override
  String toString() {
    return (StringBuffer('FieldOrderRow(')
          ..write('id: $id, ')
          ..write('orgId: $orgId, ')
          ..write('customerId: $customerId, ')
          ..write('salespersonId: $salespersonId, ')
          ..write('status: $status, ')
          ..write('notes: $notes, ')
          ..write('createdAt: $createdAt, ')
          ..write('syncStatus: $syncStatus')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, orgId, customerId, salespersonId, status,
      notes, createdAt, syncStatus);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FieldOrderRow &&
          other.id == this.id &&
          other.orgId == this.orgId &&
          other.customerId == this.customerId &&
          other.salespersonId == this.salespersonId &&
          other.status == this.status &&
          other.notes == this.notes &&
          other.createdAt == this.createdAt &&
          other.syncStatus == this.syncStatus);
}

class FieldOrdersCompanion extends UpdateCompanion<FieldOrderRow> {
  final Value<String> id;
  final Value<String> orgId;
  final Value<String> customerId;
  final Value<String> salespersonId;
  final Value<String> status;
  final Value<String?> notes;
  final Value<DateTime> createdAt;
  final Value<String> syncStatus;
  final Value<int> rowid;
  const FieldOrdersCompanion({
    this.id = const Value.absent(),
    this.orgId = const Value.absent(),
    this.customerId = const Value.absent(),
    this.salespersonId = const Value.absent(),
    this.status = const Value.absent(),
    this.notes = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.syncStatus = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  FieldOrdersCompanion.insert({
    required String id,
    required String orgId,
    required String customerId,
    required String salespersonId,
    this.status = const Value.absent(),
    this.notes = const Value.absent(),
    required DateTime createdAt,
    this.syncStatus = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        orgId = Value(orgId),
        customerId = Value(customerId),
        salespersonId = Value(salespersonId),
        createdAt = Value(createdAt);
  static Insertable<FieldOrderRow> custom({
    Expression<String>? id,
    Expression<String>? orgId,
    Expression<String>? customerId,
    Expression<String>? salespersonId,
    Expression<String>? status,
    Expression<String>? notes,
    Expression<DateTime>? createdAt,
    Expression<String>? syncStatus,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (orgId != null) 'org_id': orgId,
      if (customerId != null) 'customer_id': customerId,
      if (salespersonId != null) 'salesperson_id': salespersonId,
      if (status != null) 'status': status,
      if (notes != null) 'notes': notes,
      if (createdAt != null) 'created_at': createdAt,
      if (syncStatus != null) 'sync_status': syncStatus,
      if (rowid != null) 'rowid': rowid,
    });
  }

  FieldOrdersCompanion copyWith(
      {Value<String>? id,
      Value<String>? orgId,
      Value<String>? customerId,
      Value<String>? salespersonId,
      Value<String>? status,
      Value<String?>? notes,
      Value<DateTime>? createdAt,
      Value<String>? syncStatus,
      Value<int>? rowid}) {
    return FieldOrdersCompanion(
      id: id ?? this.id,
      orgId: orgId ?? this.orgId,
      customerId: customerId ?? this.customerId,
      salespersonId: salespersonId ?? this.salespersonId,
      status: status ?? this.status,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
      syncStatus: syncStatus ?? this.syncStatus,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (orgId.present) {
      map['org_id'] = Variable<String>(orgId.value);
    }
    if (customerId.present) {
      map['customer_id'] = Variable<String>(customerId.value);
    }
    if (salespersonId.present) {
      map['salesperson_id'] = Variable<String>(salespersonId.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (syncStatus.present) {
      map['sync_status'] = Variable<String>(syncStatus.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FieldOrdersCompanion(')
          ..write('id: $id, ')
          ..write('orgId: $orgId, ')
          ..write('customerId: $customerId, ')
          ..write('salespersonId: $salespersonId, ')
          ..write('status: $status, ')
          ..write('notes: $notes, ')
          ..write('createdAt: $createdAt, ')
          ..write('syncStatus: $syncStatus, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $FieldOrderItemsTable extends FieldOrderItems
    with TableInfo<$FieldOrderItemsTable, FieldOrderItemRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FieldOrderItemsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _fieldOrderIdMeta =
      const VerificationMeta('fieldOrderId');
  @override
  late final GeneratedColumn<String> fieldOrderId = GeneratedColumn<String>(
      'field_order_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _productIdMeta =
      const VerificationMeta('productId');
  @override
  late final GeneratedColumn<String> productId = GeneratedColumn<String>(
      'product_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _uomIdMeta = const VerificationMeta('uomId');
  @override
  late final GeneratedColumn<String> uomId = GeneratedColumn<String>(
      'uom_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _quantityMeta =
      const VerificationMeta('quantity');
  @override
  late final GeneratedColumn<double> quantity = GeneratedColumn<double>(
      'quantity', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _priceAtSubmitMeta =
      const VerificationMeta('priceAtSubmit');
  @override
  late final GeneratedColumn<double> priceAtSubmit = GeneratedColumn<double>(
      'price_at_submit', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _syncStatusMeta =
      const VerificationMeta('syncStatus');
  @override
  late final GeneratedColumn<String> syncStatus = GeneratedColumn<String>(
      'sync_status', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('pending'));
  @override
  List<GeneratedColumn> get $columns =>
      [id, fieldOrderId, productId, uomId, quantity, priceAtSubmit, syncStatus];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'field_order_items';
  @override
  VerificationContext validateIntegrity(Insertable<FieldOrderItemRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('field_order_id')) {
      context.handle(
          _fieldOrderIdMeta,
          fieldOrderId.isAcceptableOrUnknown(
              data['field_order_id']!, _fieldOrderIdMeta));
    } else if (isInserting) {
      context.missing(_fieldOrderIdMeta);
    }
    if (data.containsKey('product_id')) {
      context.handle(_productIdMeta,
          productId.isAcceptableOrUnknown(data['product_id']!, _productIdMeta));
    } else if (isInserting) {
      context.missing(_productIdMeta);
    }
    if (data.containsKey('uom_id')) {
      context.handle(
          _uomIdMeta, uomId.isAcceptableOrUnknown(data['uom_id']!, _uomIdMeta));
    }
    if (data.containsKey('quantity')) {
      context.handle(_quantityMeta,
          quantity.isAcceptableOrUnknown(data['quantity']!, _quantityMeta));
    }
    if (data.containsKey('price_at_submit')) {
      context.handle(
          _priceAtSubmitMeta,
          priceAtSubmit.isAcceptableOrUnknown(
              data['price_at_submit']!, _priceAtSubmitMeta));
    }
    if (data.containsKey('sync_status')) {
      context.handle(
          _syncStatusMeta,
          syncStatus.isAcceptableOrUnknown(
              data['sync_status']!, _syncStatusMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  FieldOrderItemRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return FieldOrderItemRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      fieldOrderId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}field_order_id'])!,
      productId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}product_id'])!,
      uomId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}uom_id']),
      quantity: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}quantity'])!,
      priceAtSubmit: attachedDatabase.typeMapping.read(
          DriftSqlType.double, data['${effectivePrefix}price_at_submit'])!,
      syncStatus: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_status'])!,
    );
  }

  @override
  $FieldOrderItemsTable createAlias(String alias) {
    return $FieldOrderItemsTable(attachedDatabase, alias);
  }
}

class FieldOrderItemRow extends DataClass
    implements Insertable<FieldOrderItemRow> {
  final String id;
  final String fieldOrderId;
  final String productId;
  final String? uomId;
  final double quantity;
  final double priceAtSubmit;
  final String syncStatus;
  const FieldOrderItemRow(
      {required this.id,
      required this.fieldOrderId,
      required this.productId,
      this.uomId,
      required this.quantity,
      required this.priceAtSubmit,
      required this.syncStatus});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['field_order_id'] = Variable<String>(fieldOrderId);
    map['product_id'] = Variable<String>(productId);
    if (!nullToAbsent || uomId != null) {
      map['uom_id'] = Variable<String>(uomId);
    }
    map['quantity'] = Variable<double>(quantity);
    map['price_at_submit'] = Variable<double>(priceAtSubmit);
    map['sync_status'] = Variable<String>(syncStatus);
    return map;
  }

  FieldOrderItemsCompanion toCompanion(bool nullToAbsent) {
    return FieldOrderItemsCompanion(
      id: Value(id),
      fieldOrderId: Value(fieldOrderId),
      productId: Value(productId),
      uomId:
          uomId == null && nullToAbsent ? const Value.absent() : Value(uomId),
      quantity: Value(quantity),
      priceAtSubmit: Value(priceAtSubmit),
      syncStatus: Value(syncStatus),
    );
  }

  factory FieldOrderItemRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return FieldOrderItemRow(
      id: serializer.fromJson<String>(json['id']),
      fieldOrderId: serializer.fromJson<String>(json['fieldOrderId']),
      productId: serializer.fromJson<String>(json['productId']),
      uomId: serializer.fromJson<String?>(json['uomId']),
      quantity: serializer.fromJson<double>(json['quantity']),
      priceAtSubmit: serializer.fromJson<double>(json['priceAtSubmit']),
      syncStatus: serializer.fromJson<String>(json['syncStatus']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'fieldOrderId': serializer.toJson<String>(fieldOrderId),
      'productId': serializer.toJson<String>(productId),
      'uomId': serializer.toJson<String?>(uomId),
      'quantity': serializer.toJson<double>(quantity),
      'priceAtSubmit': serializer.toJson<double>(priceAtSubmit),
      'syncStatus': serializer.toJson<String>(syncStatus),
    };
  }

  FieldOrderItemRow copyWith(
          {String? id,
          String? fieldOrderId,
          String? productId,
          Value<String?> uomId = const Value.absent(),
          double? quantity,
          double? priceAtSubmit,
          String? syncStatus}) =>
      FieldOrderItemRow(
        id: id ?? this.id,
        fieldOrderId: fieldOrderId ?? this.fieldOrderId,
        productId: productId ?? this.productId,
        uomId: uomId.present ? uomId.value : this.uomId,
        quantity: quantity ?? this.quantity,
        priceAtSubmit: priceAtSubmit ?? this.priceAtSubmit,
        syncStatus: syncStatus ?? this.syncStatus,
      );
  FieldOrderItemRow copyWithCompanion(FieldOrderItemsCompanion data) {
    return FieldOrderItemRow(
      id: data.id.present ? data.id.value : this.id,
      fieldOrderId: data.fieldOrderId.present
          ? data.fieldOrderId.value
          : this.fieldOrderId,
      productId: data.productId.present ? data.productId.value : this.productId,
      uomId: data.uomId.present ? data.uomId.value : this.uomId,
      quantity: data.quantity.present ? data.quantity.value : this.quantity,
      priceAtSubmit: data.priceAtSubmit.present
          ? data.priceAtSubmit.value
          : this.priceAtSubmit,
      syncStatus:
          data.syncStatus.present ? data.syncStatus.value : this.syncStatus,
    );
  }

  @override
  String toString() {
    return (StringBuffer('FieldOrderItemRow(')
          ..write('id: $id, ')
          ..write('fieldOrderId: $fieldOrderId, ')
          ..write('productId: $productId, ')
          ..write('uomId: $uomId, ')
          ..write('quantity: $quantity, ')
          ..write('priceAtSubmit: $priceAtSubmit, ')
          ..write('syncStatus: $syncStatus')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, fieldOrderId, productId, uomId, quantity, priceAtSubmit, syncStatus);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FieldOrderItemRow &&
          other.id == this.id &&
          other.fieldOrderId == this.fieldOrderId &&
          other.productId == this.productId &&
          other.uomId == this.uomId &&
          other.quantity == this.quantity &&
          other.priceAtSubmit == this.priceAtSubmit &&
          other.syncStatus == this.syncStatus);
}

class FieldOrderItemsCompanion extends UpdateCompanion<FieldOrderItemRow> {
  final Value<String> id;
  final Value<String> fieldOrderId;
  final Value<String> productId;
  final Value<String?> uomId;
  final Value<double> quantity;
  final Value<double> priceAtSubmit;
  final Value<String> syncStatus;
  final Value<int> rowid;
  const FieldOrderItemsCompanion({
    this.id = const Value.absent(),
    this.fieldOrderId = const Value.absent(),
    this.productId = const Value.absent(),
    this.uomId = const Value.absent(),
    this.quantity = const Value.absent(),
    this.priceAtSubmit = const Value.absent(),
    this.syncStatus = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  FieldOrderItemsCompanion.insert({
    required String id,
    required String fieldOrderId,
    required String productId,
    this.uomId = const Value.absent(),
    this.quantity = const Value.absent(),
    this.priceAtSubmit = const Value.absent(),
    this.syncStatus = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        fieldOrderId = Value(fieldOrderId),
        productId = Value(productId);
  static Insertable<FieldOrderItemRow> custom({
    Expression<String>? id,
    Expression<String>? fieldOrderId,
    Expression<String>? productId,
    Expression<String>? uomId,
    Expression<double>? quantity,
    Expression<double>? priceAtSubmit,
    Expression<String>? syncStatus,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (fieldOrderId != null) 'field_order_id': fieldOrderId,
      if (productId != null) 'product_id': productId,
      if (uomId != null) 'uom_id': uomId,
      if (quantity != null) 'quantity': quantity,
      if (priceAtSubmit != null) 'price_at_submit': priceAtSubmit,
      if (syncStatus != null) 'sync_status': syncStatus,
      if (rowid != null) 'rowid': rowid,
    });
  }

  FieldOrderItemsCompanion copyWith(
      {Value<String>? id,
      Value<String>? fieldOrderId,
      Value<String>? productId,
      Value<String?>? uomId,
      Value<double>? quantity,
      Value<double>? priceAtSubmit,
      Value<String>? syncStatus,
      Value<int>? rowid}) {
    return FieldOrderItemsCompanion(
      id: id ?? this.id,
      fieldOrderId: fieldOrderId ?? this.fieldOrderId,
      productId: productId ?? this.productId,
      uomId: uomId ?? this.uomId,
      quantity: quantity ?? this.quantity,
      priceAtSubmit: priceAtSubmit ?? this.priceAtSubmit,
      syncStatus: syncStatus ?? this.syncStatus,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (fieldOrderId.present) {
      map['field_order_id'] = Variable<String>(fieldOrderId.value);
    }
    if (productId.present) {
      map['product_id'] = Variable<String>(productId.value);
    }
    if (uomId.present) {
      map['uom_id'] = Variable<String>(uomId.value);
    }
    if (quantity.present) {
      map['quantity'] = Variable<double>(quantity.value);
    }
    if (priceAtSubmit.present) {
      map['price_at_submit'] = Variable<double>(priceAtSubmit.value);
    }
    if (syncStatus.present) {
      map['sync_status'] = Variable<String>(syncStatus.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FieldOrderItemsCompanion(')
          ..write('id: $id, ')
          ..write('fieldOrderId: $fieldOrderId, ')
          ..write('productId: $productId, ')
          ..write('uomId: $uomId, ')
          ..write('quantity: $quantity, ')
          ..write('priceAtSubmit: $priceAtSubmit, ')
          ..write('syncStatus: $syncStatus, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $CustomersTable customers = $CustomersTable(this);
  late final $SalesRoutesTableTable salesRoutesTable =
      $SalesRoutesTableTable(this);
  late final $RouteStopsTable routeStops = $RouteStopsTable(this);
  late final $TripsTable trips = $TripsTable(this);
  late final $TripStopsTable tripStops = $TripStopsTable(this);
  late final $VisitsTable visits = $VisitsTable(this);
  late final $AppConfigTable appConfig = $AppConfigTable(this);
  late final $AuditLogsTable auditLogs = $AuditLogsTable(this);
  late final $UsersTable users = $UsersTable(this);
  late final $RouteAssignmentsTable routeAssignments =
      $RouteAssignmentsTable(this);
  late final $UploadQueueTable uploadQueue = $UploadQueueTable(this);
  late final $DeliveriesTable deliveries = $DeliveriesTable(this);
  late final $DeliveryStopsTable deliveryStops = $DeliveryStopsTable(this);
  late final $OrgsTable orgs = $OrgsTable(this);
  late final $CompetitorCategoriesTable competitorCategories =
      $CompetitorCategoriesTable(this);
  late final $ProductsTable products = $ProductsTable(this);
  late final $CompetitorSpottingsTable competitorSpottings =
      $CompetitorSpottingsTable(this);
  late final $PlacementAuditsTable placementAudits =
      $PlacementAuditsTable(this);
  late final $CatalogProductsTable catalogProducts =
      $CatalogProductsTable(this);
  late final $FieldOrdersTable fieldOrders = $FieldOrdersTable(this);
  late final $FieldOrderItemsTable fieldOrderItems =
      $FieldOrderItemsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        customers,
        salesRoutesTable,
        routeStops,
        trips,
        tripStops,
        visits,
        appConfig,
        auditLogs,
        users,
        routeAssignments,
        uploadQueue,
        deliveries,
        deliveryStops,
        orgs,
        competitorCategories,
        products,
        competitorSpottings,
        placementAudits,
        catalogProducts,
        fieldOrders,
        fieldOrderItems
      ];
}

typedef $$CustomersTableCreateCompanionBuilder = CustomersCompanion Function({
  required String id,
  required String code,
  required String shopName,
  required String contactPerson,
  required String phone,
  required String address,
  Value<String?> category,
  Value<String?> groupName,
  Value<double?> latitude,
  Value<double?> longitude,
  Value<bool> isActive,
  Value<DateTime?> updatedAt,
  Value<String?> ntnGst,
  Value<String?> orgId,
  Value<String> syncStatus,
  Value<int> rowid,
});
typedef $$CustomersTableUpdateCompanionBuilder = CustomersCompanion Function({
  Value<String> id,
  Value<String> code,
  Value<String> shopName,
  Value<String> contactPerson,
  Value<String> phone,
  Value<String> address,
  Value<String?> category,
  Value<String?> groupName,
  Value<double?> latitude,
  Value<double?> longitude,
  Value<bool> isActive,
  Value<DateTime?> updatedAt,
  Value<String?> ntnGst,
  Value<String?> orgId,
  Value<String> syncStatus,
  Value<int> rowid,
});

final class $$CustomersTableReferences
    extends BaseReferences<_$AppDatabase, $CustomersTable, CustomersData> {
  $$CustomersTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$RouteStopsTable, List<RouteStopsData>>
      _routeStopsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
          db.routeStops,
          aliasName:
              $_aliasNameGenerator(db.customers.id, db.routeStops.customerId));

  $$RouteStopsTableProcessedTableManager get routeStopsRefs {
    final manager = $$RouteStopsTableTableManager($_db, $_db.routeStops)
        .filter((f) => f.customerId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_routeStopsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$TripStopsTable, List<TripStopsData>>
      _tripStopsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
          db.tripStops,
          aliasName:
              $_aliasNameGenerator(db.customers.id, db.tripStops.customerId));

  $$TripStopsTableProcessedTableManager get tripStopsRefs {
    final manager = $$TripStopsTableTableManager($_db, $_db.tripStops)
        .filter((f) => f.customerId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_tripStopsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$VisitsTable, List<VisitsData>> _visitsRefsTable(
          _$AppDatabase db) =>
      MultiTypedResultKey.fromTable(db.visits,
          aliasName:
              $_aliasNameGenerator(db.customers.id, db.visits.customerId));

  $$VisitsTableProcessedTableManager get visitsRefs {
    final manager = $$VisitsTableTableManager($_db, $_db.visits)
        .filter((f) => f.customerId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_visitsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$CustomersTableFilterComposer
    extends Composer<_$AppDatabase, $CustomersTable> {
  $$CustomersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get code => $composableBuilder(
      column: $table.code, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get shopName => $composableBuilder(
      column: $table.shopName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get contactPerson => $composableBuilder(
      column: $table.contactPerson, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get phone => $composableBuilder(
      column: $table.phone, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get address => $composableBuilder(
      column: $table.address, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get category => $composableBuilder(
      column: $table.category, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get groupName => $composableBuilder(
      column: $table.groupName, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get latitude => $composableBuilder(
      column: $table.latitude, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get longitude => $composableBuilder(
      column: $table.longitude, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isActive => $composableBuilder(
      column: $table.isActive, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get ntnGst => $composableBuilder(
      column: $table.ntnGst, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => ColumnFilters(column));

  Expression<bool> routeStopsRefs(
      Expression<bool> Function($$RouteStopsTableFilterComposer f) f) {
    final $$RouteStopsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.routeStops,
        getReferencedColumn: (t) => t.customerId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$RouteStopsTableFilterComposer(
              $db: $db,
              $table: $db.routeStops,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> tripStopsRefs(
      Expression<bool> Function($$TripStopsTableFilterComposer f) f) {
    final $$TripStopsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.tripStops,
        getReferencedColumn: (t) => t.customerId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$TripStopsTableFilterComposer(
              $db: $db,
              $table: $db.tripStops,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> visitsRefs(
      Expression<bool> Function($$VisitsTableFilterComposer f) f) {
    final $$VisitsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.visits,
        getReferencedColumn: (t) => t.customerId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$VisitsTableFilterComposer(
              $db: $db,
              $table: $db.visits,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$CustomersTableOrderingComposer
    extends Composer<_$AppDatabase, $CustomersTable> {
  $$CustomersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get code => $composableBuilder(
      column: $table.code, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get shopName => $composableBuilder(
      column: $table.shopName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get contactPerson => $composableBuilder(
      column: $table.contactPerson,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get phone => $composableBuilder(
      column: $table.phone, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get address => $composableBuilder(
      column: $table.address, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get category => $composableBuilder(
      column: $table.category, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get groupName => $composableBuilder(
      column: $table.groupName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get latitude => $composableBuilder(
      column: $table.latitude, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get longitude => $composableBuilder(
      column: $table.longitude, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isActive => $composableBuilder(
      column: $table.isActive, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get ntnGst => $composableBuilder(
      column: $table.ntnGst, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => ColumnOrderings(column));
}

class $$CustomersTableAnnotationComposer
    extends Composer<_$AppDatabase, $CustomersTable> {
  $$CustomersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get code =>
      $composableBuilder(column: $table.code, builder: (column) => column);

  GeneratedColumn<String> get shopName =>
      $composableBuilder(column: $table.shopName, builder: (column) => column);

  GeneratedColumn<String> get contactPerson => $composableBuilder(
      column: $table.contactPerson, builder: (column) => column);

  GeneratedColumn<String> get phone =>
      $composableBuilder(column: $table.phone, builder: (column) => column);

  GeneratedColumn<String> get address =>
      $composableBuilder(column: $table.address, builder: (column) => column);

  GeneratedColumn<String> get category =>
      $composableBuilder(column: $table.category, builder: (column) => column);

  GeneratedColumn<String> get groupName =>
      $composableBuilder(column: $table.groupName, builder: (column) => column);

  GeneratedColumn<double> get latitude =>
      $composableBuilder(column: $table.latitude, builder: (column) => column);

  GeneratedColumn<double> get longitude =>
      $composableBuilder(column: $table.longitude, builder: (column) => column);

  GeneratedColumn<bool> get isActive =>
      $composableBuilder(column: $table.isActive, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get ntnGst =>
      $composableBuilder(column: $table.ntnGst, builder: (column) => column);

  GeneratedColumn<String> get orgId =>
      $composableBuilder(column: $table.orgId, builder: (column) => column);

  GeneratedColumn<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => column);

  Expression<T> routeStopsRefs<T extends Object>(
      Expression<T> Function($$RouteStopsTableAnnotationComposer a) f) {
    final $$RouteStopsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.routeStops,
        getReferencedColumn: (t) => t.customerId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$RouteStopsTableAnnotationComposer(
              $db: $db,
              $table: $db.routeStops,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<T> tripStopsRefs<T extends Object>(
      Expression<T> Function($$TripStopsTableAnnotationComposer a) f) {
    final $$TripStopsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.tripStops,
        getReferencedColumn: (t) => t.customerId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$TripStopsTableAnnotationComposer(
              $db: $db,
              $table: $db.tripStops,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<T> visitsRefs<T extends Object>(
      Expression<T> Function($$VisitsTableAnnotationComposer a) f) {
    final $$VisitsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.visits,
        getReferencedColumn: (t) => t.customerId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$VisitsTableAnnotationComposer(
              $db: $db,
              $table: $db.visits,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$CustomersTableTableManager extends RootTableManager<
    _$AppDatabase,
    $CustomersTable,
    CustomersData,
    $$CustomersTableFilterComposer,
    $$CustomersTableOrderingComposer,
    $$CustomersTableAnnotationComposer,
    $$CustomersTableCreateCompanionBuilder,
    $$CustomersTableUpdateCompanionBuilder,
    (CustomersData, $$CustomersTableReferences),
    CustomersData,
    PrefetchHooks Function(
        {bool routeStopsRefs, bool tripStopsRefs, bool visitsRefs})> {
  $$CustomersTableTableManager(_$AppDatabase db, $CustomersTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CustomersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CustomersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CustomersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> code = const Value.absent(),
            Value<String> shopName = const Value.absent(),
            Value<String> contactPerson = const Value.absent(),
            Value<String> phone = const Value.absent(),
            Value<String> address = const Value.absent(),
            Value<String?> category = const Value.absent(),
            Value<String?> groupName = const Value.absent(),
            Value<double?> latitude = const Value.absent(),
            Value<double?> longitude = const Value.absent(),
            Value<bool> isActive = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
            Value<String?> ntnGst = const Value.absent(),
            Value<String?> orgId = const Value.absent(),
            Value<String> syncStatus = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              CustomersCompanion(
            id: id,
            code: code,
            shopName: shopName,
            contactPerson: contactPerson,
            phone: phone,
            address: address,
            category: category,
            groupName: groupName,
            latitude: latitude,
            longitude: longitude,
            isActive: isActive,
            updatedAt: updatedAt,
            ntnGst: ntnGst,
            orgId: orgId,
            syncStatus: syncStatus,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String code,
            required String shopName,
            required String contactPerson,
            required String phone,
            required String address,
            Value<String?> category = const Value.absent(),
            Value<String?> groupName = const Value.absent(),
            Value<double?> latitude = const Value.absent(),
            Value<double?> longitude = const Value.absent(),
            Value<bool> isActive = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
            Value<String?> ntnGst = const Value.absent(),
            Value<String?> orgId = const Value.absent(),
            Value<String> syncStatus = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              CustomersCompanion.insert(
            id: id,
            code: code,
            shopName: shopName,
            contactPerson: contactPerson,
            phone: phone,
            address: address,
            category: category,
            groupName: groupName,
            latitude: latitude,
            longitude: longitude,
            isActive: isActive,
            updatedAt: updatedAt,
            ntnGst: ntnGst,
            orgId: orgId,
            syncStatus: syncStatus,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$CustomersTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: (
              {routeStopsRefs = false,
              tripStopsRefs = false,
              visitsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (routeStopsRefs) db.routeStops,
                if (tripStopsRefs) db.tripStops,
                if (visitsRefs) db.visits
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (routeStopsRefs)
                    await $_getPrefetchedData<CustomersData, $CustomersTable,
                            RouteStopsData>(
                        currentTable: table,
                        referencedTable:
                            $$CustomersTableReferences._routeStopsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$CustomersTableReferences(db, table, p0)
                                .routeStopsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.customerId == item.id),
                        typedResults: items),
                  if (tripStopsRefs)
                    await $_getPrefetchedData<CustomersData, $CustomersTable,
                            TripStopsData>(
                        currentTable: table,
                        referencedTable:
                            $$CustomersTableReferences._tripStopsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$CustomersTableReferences(db, table, p0)
                                .tripStopsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.customerId == item.id),
                        typedResults: items),
                  if (visitsRefs)
                    await $_getPrefetchedData<CustomersData, $CustomersTable,
                            VisitsData>(
                        currentTable: table,
                        referencedTable:
                            $$CustomersTableReferences._visitsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$CustomersTableReferences(db, table, p0)
                                .visitsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.customerId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$CustomersTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $CustomersTable,
    CustomersData,
    $$CustomersTableFilterComposer,
    $$CustomersTableOrderingComposer,
    $$CustomersTableAnnotationComposer,
    $$CustomersTableCreateCompanionBuilder,
    $$CustomersTableUpdateCompanionBuilder,
    (CustomersData, $$CustomersTableReferences),
    CustomersData,
    PrefetchHooks Function(
        {bool routeStopsRefs, bool tripStopsRefs, bool visitsRefs})>;
typedef $$SalesRoutesTableTableCreateCompanionBuilder
    = SalesRoutesTableCompanion Function({
  required String id,
  required String name,
  required String kind,
  Value<bool> isActive,
  Value<DateTime?> createdAt,
  Value<DateTime?> updatedAt,
  Value<String?> orgId,
  Value<int> rowid,
});
typedef $$SalesRoutesTableTableUpdateCompanionBuilder
    = SalesRoutesTableCompanion Function({
  Value<String> id,
  Value<String> name,
  Value<String> kind,
  Value<bool> isActive,
  Value<DateTime?> createdAt,
  Value<DateTime?> updatedAt,
  Value<String?> orgId,
  Value<int> rowid,
});

final class $$SalesRoutesTableTableReferences extends BaseReferences<
    _$AppDatabase, $SalesRoutesTableTable, SalesRoutesData> {
  $$SalesRoutesTableTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$RouteStopsTable, List<RouteStopsData>>
      _routeStopsRefsTable(_$AppDatabase db) =>
          MultiTypedResultKey.fromTable(db.routeStops,
              aliasName: $_aliasNameGenerator(
                  db.salesRoutesTable.id, db.routeStops.routeId));

  $$RouteStopsTableProcessedTableManager get routeStopsRefs {
    final manager = $$RouteStopsTableTableManager($_db, $_db.routeStops)
        .filter((f) => f.routeId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_routeStopsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$SalesRoutesTableTableFilterComposer
    extends Composer<_$AppDatabase, $SalesRoutesTableTable> {
  $$SalesRoutesTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isActive => $composableBuilder(
      column: $table.isActive, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnFilters(column));

  Expression<bool> routeStopsRefs(
      Expression<bool> Function($$RouteStopsTableFilterComposer f) f) {
    final $$RouteStopsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.routeStops,
        getReferencedColumn: (t) => t.routeId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$RouteStopsTableFilterComposer(
              $db: $db,
              $table: $db.routeStops,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$SalesRoutesTableTableOrderingComposer
    extends Composer<_$AppDatabase, $SalesRoutesTableTable> {
  $$SalesRoutesTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isActive => $composableBuilder(
      column: $table.isActive, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnOrderings(column));
}

class $$SalesRoutesTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $SalesRoutesTableTable> {
  $$SalesRoutesTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<bool> get isActive =>
      $composableBuilder(column: $table.isActive, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get orgId =>
      $composableBuilder(column: $table.orgId, builder: (column) => column);

  Expression<T> routeStopsRefs<T extends Object>(
      Expression<T> Function($$RouteStopsTableAnnotationComposer a) f) {
    final $$RouteStopsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.routeStops,
        getReferencedColumn: (t) => t.routeId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$RouteStopsTableAnnotationComposer(
              $db: $db,
              $table: $db.routeStops,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$SalesRoutesTableTableTableManager extends RootTableManager<
    _$AppDatabase,
    $SalesRoutesTableTable,
    SalesRoutesData,
    $$SalesRoutesTableTableFilterComposer,
    $$SalesRoutesTableTableOrderingComposer,
    $$SalesRoutesTableTableAnnotationComposer,
    $$SalesRoutesTableTableCreateCompanionBuilder,
    $$SalesRoutesTableTableUpdateCompanionBuilder,
    (SalesRoutesData, $$SalesRoutesTableTableReferences),
    SalesRoutesData,
    PrefetchHooks Function({bool routeStopsRefs})> {
  $$SalesRoutesTableTableTableManager(
      _$AppDatabase db, $SalesRoutesTableTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SalesRoutesTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SalesRoutesTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SalesRoutesTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<String> kind = const Value.absent(),
            Value<bool> isActive = const Value.absent(),
            Value<DateTime?> createdAt = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
            Value<String?> orgId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SalesRoutesTableCompanion(
            id: id,
            name: name,
            kind: kind,
            isActive: isActive,
            createdAt: createdAt,
            updatedAt: updatedAt,
            orgId: orgId,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String name,
            required String kind,
            Value<bool> isActive = const Value.absent(),
            Value<DateTime?> createdAt = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
            Value<String?> orgId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SalesRoutesTableCompanion.insert(
            id: id,
            name: name,
            kind: kind,
            isActive: isActive,
            createdAt: createdAt,
            updatedAt: updatedAt,
            orgId: orgId,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$SalesRoutesTableTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({routeStopsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (routeStopsRefs) db.routeStops],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (routeStopsRefs)
                    await $_getPrefetchedData<SalesRoutesData,
                            $SalesRoutesTableTable, RouteStopsData>(
                        currentTable: table,
                        referencedTable: $$SalesRoutesTableTableReferences
                            ._routeStopsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$SalesRoutesTableTableReferences(db, table, p0)
                                .routeStopsRefs,
                        referencedItemsForCurrentItem: (item,
                                referencedItems) =>
                            referencedItems.where((e) => e.routeId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$SalesRoutesTableTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $SalesRoutesTableTable,
    SalesRoutesData,
    $$SalesRoutesTableTableFilterComposer,
    $$SalesRoutesTableTableOrderingComposer,
    $$SalesRoutesTableTableAnnotationComposer,
    $$SalesRoutesTableTableCreateCompanionBuilder,
    $$SalesRoutesTableTableUpdateCompanionBuilder,
    (SalesRoutesData, $$SalesRoutesTableTableReferences),
    SalesRoutesData,
    PrefetchHooks Function({bool routeStopsRefs})>;
typedef $$RouteStopsTableCreateCompanionBuilder = RouteStopsCompanion Function({
  required String routeId,
  required String customerId,
  required int position,
  Value<int> rowid,
});
typedef $$RouteStopsTableUpdateCompanionBuilder = RouteStopsCompanion Function({
  Value<String> routeId,
  Value<String> customerId,
  Value<int> position,
  Value<int> rowid,
});

final class $$RouteStopsTableReferences
    extends BaseReferences<_$AppDatabase, $RouteStopsTable, RouteStopsData> {
  $$RouteStopsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $SalesRoutesTableTable _routeIdTable(_$AppDatabase db) =>
      db.salesRoutesTable.createAlias(
          $_aliasNameGenerator(db.routeStops.routeId, db.salesRoutesTable.id));

  $$SalesRoutesTableTableProcessedTableManager get routeId {
    final $_column = $_itemColumn<String>('route_id')!;

    final manager =
        $$SalesRoutesTableTableTableManager($_db, $_db.salesRoutesTable)
            .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_routeIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static $CustomersTable _customerIdTable(_$AppDatabase db) =>
      db.customers.createAlias(
          $_aliasNameGenerator(db.routeStops.customerId, db.customers.id));

  $$CustomersTableProcessedTableManager get customerId {
    final $_column = $_itemColumn<String>('customer_id')!;

    final manager = $$CustomersTableTableManager($_db, $_db.customers)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_customerIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$RouteStopsTableFilterComposer
    extends Composer<_$AppDatabase, $RouteStopsTable> {
  $$RouteStopsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get position => $composableBuilder(
      column: $table.position, builder: (column) => ColumnFilters(column));

  $$SalesRoutesTableTableFilterComposer get routeId {
    final $$SalesRoutesTableTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.routeId,
        referencedTable: $db.salesRoutesTable,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SalesRoutesTableTableFilterComposer(
              $db: $db,
              $table: $db.salesRoutesTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$CustomersTableFilterComposer get customerId {
    final $$CustomersTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.customerId,
        referencedTable: $db.customers,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$CustomersTableFilterComposer(
              $db: $db,
              $table: $db.customers,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$RouteStopsTableOrderingComposer
    extends Composer<_$AppDatabase, $RouteStopsTable> {
  $$RouteStopsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get position => $composableBuilder(
      column: $table.position, builder: (column) => ColumnOrderings(column));

  $$SalesRoutesTableTableOrderingComposer get routeId {
    final $$SalesRoutesTableTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.routeId,
        referencedTable: $db.salesRoutesTable,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SalesRoutesTableTableOrderingComposer(
              $db: $db,
              $table: $db.salesRoutesTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$CustomersTableOrderingComposer get customerId {
    final $$CustomersTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.customerId,
        referencedTable: $db.customers,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$CustomersTableOrderingComposer(
              $db: $db,
              $table: $db.customers,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$RouteStopsTableAnnotationComposer
    extends Composer<_$AppDatabase, $RouteStopsTable> {
  $$RouteStopsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  $$SalesRoutesTableTableAnnotationComposer get routeId {
    final $$SalesRoutesTableTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.routeId,
        referencedTable: $db.salesRoutesTable,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SalesRoutesTableTableAnnotationComposer(
              $db: $db,
              $table: $db.salesRoutesTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$CustomersTableAnnotationComposer get customerId {
    final $$CustomersTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.customerId,
        referencedTable: $db.customers,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$CustomersTableAnnotationComposer(
              $db: $db,
              $table: $db.customers,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$RouteStopsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $RouteStopsTable,
    RouteStopsData,
    $$RouteStopsTableFilterComposer,
    $$RouteStopsTableOrderingComposer,
    $$RouteStopsTableAnnotationComposer,
    $$RouteStopsTableCreateCompanionBuilder,
    $$RouteStopsTableUpdateCompanionBuilder,
    (RouteStopsData, $$RouteStopsTableReferences),
    RouteStopsData,
    PrefetchHooks Function({bool routeId, bool customerId})> {
  $$RouteStopsTableTableManager(_$AppDatabase db, $RouteStopsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RouteStopsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RouteStopsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RouteStopsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> routeId = const Value.absent(),
            Value<String> customerId = const Value.absent(),
            Value<int> position = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              RouteStopsCompanion(
            routeId: routeId,
            customerId: customerId,
            position: position,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String routeId,
            required String customerId,
            required int position,
            Value<int> rowid = const Value.absent(),
          }) =>
              RouteStopsCompanion.insert(
            routeId: routeId,
            customerId: customerId,
            position: position,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$RouteStopsTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({routeId = false, customerId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (routeId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.routeId,
                    referencedTable:
                        $$RouteStopsTableReferences._routeIdTable(db),
                    referencedColumn:
                        $$RouteStopsTableReferences._routeIdTable(db).id,
                  ) as T;
                }
                if (customerId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.customerId,
                    referencedTable:
                        $$RouteStopsTableReferences._customerIdTable(db),
                    referencedColumn:
                        $$RouteStopsTableReferences._customerIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$RouteStopsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $RouteStopsTable,
    RouteStopsData,
    $$RouteStopsTableFilterComposer,
    $$RouteStopsTableOrderingComposer,
    $$RouteStopsTableAnnotationComposer,
    $$RouteStopsTableCreateCompanionBuilder,
    $$RouteStopsTableUpdateCompanionBuilder,
    (RouteStopsData, $$RouteStopsTableReferences),
    RouteStopsData,
    PrefetchHooks Function({bool routeId, bool customerId})>;
typedef $$TripsTableCreateCompanionBuilder = TripsCompanion Function({
  required String id,
  required String routeId,
  required String routeName,
  required String routeKind,
  required DateTime startedAt,
  Value<DateTime?> endedAt,
  Value<String?> closeReason,
  Value<double?> startLat,
  Value<double?> startLng,
  Value<double?> endLat,
  Value<double?> endLng,
  Value<String> userId,
  Value<String> userName,
  Value<String> userRole,
  Value<String?> orgId,
  Value<int> rowid,
});
typedef $$TripsTableUpdateCompanionBuilder = TripsCompanion Function({
  Value<String> id,
  Value<String> routeId,
  Value<String> routeName,
  Value<String> routeKind,
  Value<DateTime> startedAt,
  Value<DateTime?> endedAt,
  Value<String?> closeReason,
  Value<double?> startLat,
  Value<double?> startLng,
  Value<double?> endLat,
  Value<double?> endLng,
  Value<String> userId,
  Value<String> userName,
  Value<String> userRole,
  Value<String?> orgId,
  Value<int> rowid,
});

final class $$TripsTableReferences
    extends BaseReferences<_$AppDatabase, $TripsTable, TripsData> {
  $$TripsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$TripStopsTable, List<TripStopsData>>
      _tripStopsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
          db.tripStops,
          aliasName: $_aliasNameGenerator(db.trips.id, db.tripStops.tripId));

  $$TripStopsTableProcessedTableManager get tripStopsRefs {
    final manager = $$TripStopsTableTableManager($_db, $_db.tripStops)
        .filter((f) => f.tripId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_tripStopsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$VisitsTable, List<VisitsData>> _visitsRefsTable(
          _$AppDatabase db) =>
      MultiTypedResultKey.fromTable(db.visits,
          aliasName: $_aliasNameGenerator(db.trips.id, db.visits.tripId));

  $$VisitsTableProcessedTableManager get visitsRefs {
    final manager = $$VisitsTableTableManager($_db, $_db.visits)
        .filter((f) => f.tripId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_visitsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$TripsTableFilterComposer extends Composer<_$AppDatabase, $TripsTable> {
  $$TripsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get routeId => $composableBuilder(
      column: $table.routeId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get routeName => $composableBuilder(
      column: $table.routeName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get routeKind => $composableBuilder(
      column: $table.routeKind, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get startedAt => $composableBuilder(
      column: $table.startedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get endedAt => $composableBuilder(
      column: $table.endedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get closeReason => $composableBuilder(
      column: $table.closeReason, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get startLat => $composableBuilder(
      column: $table.startLat, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get startLng => $composableBuilder(
      column: $table.startLng, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get endLat => $composableBuilder(
      column: $table.endLat, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get endLng => $composableBuilder(
      column: $table.endLng, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get userId => $composableBuilder(
      column: $table.userId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get userName => $composableBuilder(
      column: $table.userName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get userRole => $composableBuilder(
      column: $table.userRole, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnFilters(column));

  Expression<bool> tripStopsRefs(
      Expression<bool> Function($$TripStopsTableFilterComposer f) f) {
    final $$TripStopsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.tripStops,
        getReferencedColumn: (t) => t.tripId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$TripStopsTableFilterComposer(
              $db: $db,
              $table: $db.tripStops,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> visitsRefs(
      Expression<bool> Function($$VisitsTableFilterComposer f) f) {
    final $$VisitsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.visits,
        getReferencedColumn: (t) => t.tripId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$VisitsTableFilterComposer(
              $db: $db,
              $table: $db.visits,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$TripsTableOrderingComposer
    extends Composer<_$AppDatabase, $TripsTable> {
  $$TripsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get routeId => $composableBuilder(
      column: $table.routeId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get routeName => $composableBuilder(
      column: $table.routeName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get routeKind => $composableBuilder(
      column: $table.routeKind, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get startedAt => $composableBuilder(
      column: $table.startedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get endedAt => $composableBuilder(
      column: $table.endedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get closeReason => $composableBuilder(
      column: $table.closeReason, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get startLat => $composableBuilder(
      column: $table.startLat, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get startLng => $composableBuilder(
      column: $table.startLng, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get endLat => $composableBuilder(
      column: $table.endLat, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get endLng => $composableBuilder(
      column: $table.endLng, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get userId => $composableBuilder(
      column: $table.userId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get userName => $composableBuilder(
      column: $table.userName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get userRole => $composableBuilder(
      column: $table.userRole, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnOrderings(column));
}

class $$TripsTableAnnotationComposer
    extends Composer<_$AppDatabase, $TripsTable> {
  $$TripsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get routeId =>
      $composableBuilder(column: $table.routeId, builder: (column) => column);

  GeneratedColumn<String> get routeName =>
      $composableBuilder(column: $table.routeName, builder: (column) => column);

  GeneratedColumn<String> get routeKind =>
      $composableBuilder(column: $table.routeKind, builder: (column) => column);

  GeneratedColumn<DateTime> get startedAt =>
      $composableBuilder(column: $table.startedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get endedAt =>
      $composableBuilder(column: $table.endedAt, builder: (column) => column);

  GeneratedColumn<String> get closeReason => $composableBuilder(
      column: $table.closeReason, builder: (column) => column);

  GeneratedColumn<double> get startLat =>
      $composableBuilder(column: $table.startLat, builder: (column) => column);

  GeneratedColumn<double> get startLng =>
      $composableBuilder(column: $table.startLng, builder: (column) => column);

  GeneratedColumn<double> get endLat =>
      $composableBuilder(column: $table.endLat, builder: (column) => column);

  GeneratedColumn<double> get endLng =>
      $composableBuilder(column: $table.endLng, builder: (column) => column);

  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get userName =>
      $composableBuilder(column: $table.userName, builder: (column) => column);

  GeneratedColumn<String> get userRole =>
      $composableBuilder(column: $table.userRole, builder: (column) => column);

  GeneratedColumn<String> get orgId =>
      $composableBuilder(column: $table.orgId, builder: (column) => column);

  Expression<T> tripStopsRefs<T extends Object>(
      Expression<T> Function($$TripStopsTableAnnotationComposer a) f) {
    final $$TripStopsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.tripStops,
        getReferencedColumn: (t) => t.tripId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$TripStopsTableAnnotationComposer(
              $db: $db,
              $table: $db.tripStops,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<T> visitsRefs<T extends Object>(
      Expression<T> Function($$VisitsTableAnnotationComposer a) f) {
    final $$VisitsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.visits,
        getReferencedColumn: (t) => t.tripId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$VisitsTableAnnotationComposer(
              $db: $db,
              $table: $db.visits,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$TripsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $TripsTable,
    TripsData,
    $$TripsTableFilterComposer,
    $$TripsTableOrderingComposer,
    $$TripsTableAnnotationComposer,
    $$TripsTableCreateCompanionBuilder,
    $$TripsTableUpdateCompanionBuilder,
    (TripsData, $$TripsTableReferences),
    TripsData,
    PrefetchHooks Function({bool tripStopsRefs, bool visitsRefs})> {
  $$TripsTableTableManager(_$AppDatabase db, $TripsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TripsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TripsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TripsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> routeId = const Value.absent(),
            Value<String> routeName = const Value.absent(),
            Value<String> routeKind = const Value.absent(),
            Value<DateTime> startedAt = const Value.absent(),
            Value<DateTime?> endedAt = const Value.absent(),
            Value<String?> closeReason = const Value.absent(),
            Value<double?> startLat = const Value.absent(),
            Value<double?> startLng = const Value.absent(),
            Value<double?> endLat = const Value.absent(),
            Value<double?> endLng = const Value.absent(),
            Value<String> userId = const Value.absent(),
            Value<String> userName = const Value.absent(),
            Value<String> userRole = const Value.absent(),
            Value<String?> orgId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              TripsCompanion(
            id: id,
            routeId: routeId,
            routeName: routeName,
            routeKind: routeKind,
            startedAt: startedAt,
            endedAt: endedAt,
            closeReason: closeReason,
            startLat: startLat,
            startLng: startLng,
            endLat: endLat,
            endLng: endLng,
            userId: userId,
            userName: userName,
            userRole: userRole,
            orgId: orgId,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String routeId,
            required String routeName,
            required String routeKind,
            required DateTime startedAt,
            Value<DateTime?> endedAt = const Value.absent(),
            Value<String?> closeReason = const Value.absent(),
            Value<double?> startLat = const Value.absent(),
            Value<double?> startLng = const Value.absent(),
            Value<double?> endLat = const Value.absent(),
            Value<double?> endLng = const Value.absent(),
            Value<String> userId = const Value.absent(),
            Value<String> userName = const Value.absent(),
            Value<String> userRole = const Value.absent(),
            Value<String?> orgId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              TripsCompanion.insert(
            id: id,
            routeId: routeId,
            routeName: routeName,
            routeKind: routeKind,
            startedAt: startedAt,
            endedAt: endedAt,
            closeReason: closeReason,
            startLat: startLat,
            startLng: startLng,
            endLat: endLat,
            endLng: endLng,
            userId: userId,
            userName: userName,
            userRole: userRole,
            orgId: orgId,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$TripsTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: ({tripStopsRefs = false, visitsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (tripStopsRefs) db.tripStops,
                if (visitsRefs) db.visits
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (tripStopsRefs)
                    await $_getPrefetchedData<TripsData, $TripsTable,
                            TripStopsData>(
                        currentTable: table,
                        referencedTable:
                            $$TripsTableReferences._tripStopsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$TripsTableReferences(db, table, p0).tripStopsRefs,
                        referencedItemsForCurrentItem: (item,
                                referencedItems) =>
                            referencedItems.where((e) => e.tripId == item.id),
                        typedResults: items),
                  if (visitsRefs)
                    await $_getPrefetchedData<TripsData, $TripsTable,
                            VisitsData>(
                        currentTable: table,
                        referencedTable:
                            $$TripsTableReferences._visitsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$TripsTableReferences(db, table, p0).visitsRefs,
                        referencedItemsForCurrentItem: (item,
                                referencedItems) =>
                            referencedItems.where((e) => e.tripId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$TripsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $TripsTable,
    TripsData,
    $$TripsTableFilterComposer,
    $$TripsTableOrderingComposer,
    $$TripsTableAnnotationComposer,
    $$TripsTableCreateCompanionBuilder,
    $$TripsTableUpdateCompanionBuilder,
    (TripsData, $$TripsTableReferences),
    TripsData,
    PrefetchHooks Function({bool tripStopsRefs, bool visitsRefs})>;
typedef $$TripStopsTableCreateCompanionBuilder = TripStopsCompanion Function({
  required String tripId,
  required String customerId,
  required int position,
  Value<int> rowid,
});
typedef $$TripStopsTableUpdateCompanionBuilder = TripStopsCompanion Function({
  Value<String> tripId,
  Value<String> customerId,
  Value<int> position,
  Value<int> rowid,
});

final class $$TripStopsTableReferences
    extends BaseReferences<_$AppDatabase, $TripStopsTable, TripStopsData> {
  $$TripStopsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $TripsTable _tripIdTable(_$AppDatabase db) => db.trips
      .createAlias($_aliasNameGenerator(db.tripStops.tripId, db.trips.id));

  $$TripsTableProcessedTableManager get tripId {
    final $_column = $_itemColumn<String>('trip_id')!;

    final manager = $$TripsTableTableManager($_db, $_db.trips)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_tripIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static $CustomersTable _customerIdTable(_$AppDatabase db) =>
      db.customers.createAlias(
          $_aliasNameGenerator(db.tripStops.customerId, db.customers.id));

  $$CustomersTableProcessedTableManager get customerId {
    final $_column = $_itemColumn<String>('customer_id')!;

    final manager = $$CustomersTableTableManager($_db, $_db.customers)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_customerIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$TripStopsTableFilterComposer
    extends Composer<_$AppDatabase, $TripStopsTable> {
  $$TripStopsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get position => $composableBuilder(
      column: $table.position, builder: (column) => ColumnFilters(column));

  $$TripsTableFilterComposer get tripId {
    final $$TripsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.tripId,
        referencedTable: $db.trips,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$TripsTableFilterComposer(
              $db: $db,
              $table: $db.trips,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$CustomersTableFilterComposer get customerId {
    final $$CustomersTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.customerId,
        referencedTable: $db.customers,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$CustomersTableFilterComposer(
              $db: $db,
              $table: $db.customers,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$TripStopsTableOrderingComposer
    extends Composer<_$AppDatabase, $TripStopsTable> {
  $$TripStopsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get position => $composableBuilder(
      column: $table.position, builder: (column) => ColumnOrderings(column));

  $$TripsTableOrderingComposer get tripId {
    final $$TripsTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.tripId,
        referencedTable: $db.trips,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$TripsTableOrderingComposer(
              $db: $db,
              $table: $db.trips,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$CustomersTableOrderingComposer get customerId {
    final $$CustomersTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.customerId,
        referencedTable: $db.customers,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$CustomersTableOrderingComposer(
              $db: $db,
              $table: $db.customers,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$TripStopsTableAnnotationComposer
    extends Composer<_$AppDatabase, $TripStopsTable> {
  $$TripStopsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  $$TripsTableAnnotationComposer get tripId {
    final $$TripsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.tripId,
        referencedTable: $db.trips,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$TripsTableAnnotationComposer(
              $db: $db,
              $table: $db.trips,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$CustomersTableAnnotationComposer get customerId {
    final $$CustomersTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.customerId,
        referencedTable: $db.customers,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$CustomersTableAnnotationComposer(
              $db: $db,
              $table: $db.customers,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$TripStopsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $TripStopsTable,
    TripStopsData,
    $$TripStopsTableFilterComposer,
    $$TripStopsTableOrderingComposer,
    $$TripStopsTableAnnotationComposer,
    $$TripStopsTableCreateCompanionBuilder,
    $$TripStopsTableUpdateCompanionBuilder,
    (TripStopsData, $$TripStopsTableReferences),
    TripStopsData,
    PrefetchHooks Function({bool tripId, bool customerId})> {
  $$TripStopsTableTableManager(_$AppDatabase db, $TripStopsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TripStopsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TripStopsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TripStopsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> tripId = const Value.absent(),
            Value<String> customerId = const Value.absent(),
            Value<int> position = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              TripStopsCompanion(
            tripId: tripId,
            customerId: customerId,
            position: position,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String tripId,
            required String customerId,
            required int position,
            Value<int> rowid = const Value.absent(),
          }) =>
              TripStopsCompanion.insert(
            tripId: tripId,
            customerId: customerId,
            position: position,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$TripStopsTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({tripId = false, customerId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (tripId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.tripId,
                    referencedTable:
                        $$TripStopsTableReferences._tripIdTable(db),
                    referencedColumn:
                        $$TripStopsTableReferences._tripIdTable(db).id,
                  ) as T;
                }
                if (customerId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.customerId,
                    referencedTable:
                        $$TripStopsTableReferences._customerIdTable(db),
                    referencedColumn:
                        $$TripStopsTableReferences._customerIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$TripStopsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $TripStopsTable,
    TripStopsData,
    $$TripStopsTableFilterComposer,
    $$TripStopsTableOrderingComposer,
    $$TripStopsTableAnnotationComposer,
    $$TripStopsTableCreateCompanionBuilder,
    $$TripStopsTableUpdateCompanionBuilder,
    (TripStopsData, $$TripStopsTableReferences),
    TripStopsData,
    PrefetchHooks Function({bool tripId, bool customerId})>;
typedef $$VisitsTableCreateCompanionBuilder = VisitsCompanion Function({
  required String id,
  required String tripId,
  required String customerId,
  required String status,
  required DateTime timestamp,
  Value<double?> capturedLat,
  Value<double?> capturedLng,
  Value<double?> accuracyMeters,
  Value<double?> distanceMeters,
  Value<int> amount,
  Value<String?> receiptNumber,
  Value<String?> notes,
  Value<String?> skipReason,
  Value<String> photoPathsJson,
  Value<String> syncStatus,
  Value<String> userId,
  Value<String> userName,
  Value<String> userRole,
  Value<int> rowid,
});
typedef $$VisitsTableUpdateCompanionBuilder = VisitsCompanion Function({
  Value<String> id,
  Value<String> tripId,
  Value<String> customerId,
  Value<String> status,
  Value<DateTime> timestamp,
  Value<double?> capturedLat,
  Value<double?> capturedLng,
  Value<double?> accuracyMeters,
  Value<double?> distanceMeters,
  Value<int> amount,
  Value<String?> receiptNumber,
  Value<String?> notes,
  Value<String?> skipReason,
  Value<String> photoPathsJson,
  Value<String> syncStatus,
  Value<String> userId,
  Value<String> userName,
  Value<String> userRole,
  Value<int> rowid,
});

final class $$VisitsTableReferences
    extends BaseReferences<_$AppDatabase, $VisitsTable, VisitsData> {
  $$VisitsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $TripsTable _tripIdTable(_$AppDatabase db) =>
      db.trips.createAlias($_aliasNameGenerator(db.visits.tripId, db.trips.id));

  $$TripsTableProcessedTableManager get tripId {
    final $_column = $_itemColumn<String>('trip_id')!;

    final manager = $$TripsTableTableManager($_db, $_db.trips)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_tripIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static $CustomersTable _customerIdTable(_$AppDatabase db) => db.customers
      .createAlias($_aliasNameGenerator(db.visits.customerId, db.customers.id));

  $$CustomersTableProcessedTableManager get customerId {
    final $_column = $_itemColumn<String>('customer_id')!;

    final manager = $$CustomersTableTableManager($_db, $_db.customers)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_customerIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$VisitsTableFilterComposer
    extends Composer<_$AppDatabase, $VisitsTable> {
  $$VisitsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get timestamp => $composableBuilder(
      column: $table.timestamp, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get capturedLat => $composableBuilder(
      column: $table.capturedLat, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get capturedLng => $composableBuilder(
      column: $table.capturedLng, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get accuracyMeters => $composableBuilder(
      column: $table.accuracyMeters,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get distanceMeters => $composableBuilder(
      column: $table.distanceMeters,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get amount => $composableBuilder(
      column: $table.amount, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get receiptNumber => $composableBuilder(
      column: $table.receiptNumber, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get notes => $composableBuilder(
      column: $table.notes, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get skipReason => $composableBuilder(
      column: $table.skipReason, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get photoPathsJson => $composableBuilder(
      column: $table.photoPathsJson,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get userId => $composableBuilder(
      column: $table.userId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get userName => $composableBuilder(
      column: $table.userName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get userRole => $composableBuilder(
      column: $table.userRole, builder: (column) => ColumnFilters(column));

  $$TripsTableFilterComposer get tripId {
    final $$TripsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.tripId,
        referencedTable: $db.trips,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$TripsTableFilterComposer(
              $db: $db,
              $table: $db.trips,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$CustomersTableFilterComposer get customerId {
    final $$CustomersTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.customerId,
        referencedTable: $db.customers,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$CustomersTableFilterComposer(
              $db: $db,
              $table: $db.customers,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$VisitsTableOrderingComposer
    extends Composer<_$AppDatabase, $VisitsTable> {
  $$VisitsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get timestamp => $composableBuilder(
      column: $table.timestamp, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get capturedLat => $composableBuilder(
      column: $table.capturedLat, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get capturedLng => $composableBuilder(
      column: $table.capturedLng, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get accuracyMeters => $composableBuilder(
      column: $table.accuracyMeters,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get distanceMeters => $composableBuilder(
      column: $table.distanceMeters,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get amount => $composableBuilder(
      column: $table.amount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get receiptNumber => $composableBuilder(
      column: $table.receiptNumber,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get notes => $composableBuilder(
      column: $table.notes, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get skipReason => $composableBuilder(
      column: $table.skipReason, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get photoPathsJson => $composableBuilder(
      column: $table.photoPathsJson,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get userId => $composableBuilder(
      column: $table.userId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get userName => $composableBuilder(
      column: $table.userName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get userRole => $composableBuilder(
      column: $table.userRole, builder: (column) => ColumnOrderings(column));

  $$TripsTableOrderingComposer get tripId {
    final $$TripsTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.tripId,
        referencedTable: $db.trips,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$TripsTableOrderingComposer(
              $db: $db,
              $table: $db.trips,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$CustomersTableOrderingComposer get customerId {
    final $$CustomersTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.customerId,
        referencedTable: $db.customers,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$CustomersTableOrderingComposer(
              $db: $db,
              $table: $db.customers,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$VisitsTableAnnotationComposer
    extends Composer<_$AppDatabase, $VisitsTable> {
  $$VisitsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<DateTime> get timestamp =>
      $composableBuilder(column: $table.timestamp, builder: (column) => column);

  GeneratedColumn<double> get capturedLat => $composableBuilder(
      column: $table.capturedLat, builder: (column) => column);

  GeneratedColumn<double> get capturedLng => $composableBuilder(
      column: $table.capturedLng, builder: (column) => column);

  GeneratedColumn<double> get accuracyMeters => $composableBuilder(
      column: $table.accuracyMeters, builder: (column) => column);

  GeneratedColumn<double> get distanceMeters => $composableBuilder(
      column: $table.distanceMeters, builder: (column) => column);

  GeneratedColumn<int> get amount =>
      $composableBuilder(column: $table.amount, builder: (column) => column);

  GeneratedColumn<String> get receiptNumber => $composableBuilder(
      column: $table.receiptNumber, builder: (column) => column);

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<String> get skipReason => $composableBuilder(
      column: $table.skipReason, builder: (column) => column);

  GeneratedColumn<String> get photoPathsJson => $composableBuilder(
      column: $table.photoPathsJson, builder: (column) => column);

  GeneratedColumn<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => column);

  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get userName =>
      $composableBuilder(column: $table.userName, builder: (column) => column);

  GeneratedColumn<String> get userRole =>
      $composableBuilder(column: $table.userRole, builder: (column) => column);

  $$TripsTableAnnotationComposer get tripId {
    final $$TripsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.tripId,
        referencedTable: $db.trips,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$TripsTableAnnotationComposer(
              $db: $db,
              $table: $db.trips,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$CustomersTableAnnotationComposer get customerId {
    final $$CustomersTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.customerId,
        referencedTable: $db.customers,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$CustomersTableAnnotationComposer(
              $db: $db,
              $table: $db.customers,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$VisitsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $VisitsTable,
    VisitsData,
    $$VisitsTableFilterComposer,
    $$VisitsTableOrderingComposer,
    $$VisitsTableAnnotationComposer,
    $$VisitsTableCreateCompanionBuilder,
    $$VisitsTableUpdateCompanionBuilder,
    (VisitsData, $$VisitsTableReferences),
    VisitsData,
    PrefetchHooks Function({bool tripId, bool customerId})> {
  $$VisitsTableTableManager(_$AppDatabase db, $VisitsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$VisitsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$VisitsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$VisitsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> tripId = const Value.absent(),
            Value<String> customerId = const Value.absent(),
            Value<String> status = const Value.absent(),
            Value<DateTime> timestamp = const Value.absent(),
            Value<double?> capturedLat = const Value.absent(),
            Value<double?> capturedLng = const Value.absent(),
            Value<double?> accuracyMeters = const Value.absent(),
            Value<double?> distanceMeters = const Value.absent(),
            Value<int> amount = const Value.absent(),
            Value<String?> receiptNumber = const Value.absent(),
            Value<String?> notes = const Value.absent(),
            Value<String?> skipReason = const Value.absent(),
            Value<String> photoPathsJson = const Value.absent(),
            Value<String> syncStatus = const Value.absent(),
            Value<String> userId = const Value.absent(),
            Value<String> userName = const Value.absent(),
            Value<String> userRole = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              VisitsCompanion(
            id: id,
            tripId: tripId,
            customerId: customerId,
            status: status,
            timestamp: timestamp,
            capturedLat: capturedLat,
            capturedLng: capturedLng,
            accuracyMeters: accuracyMeters,
            distanceMeters: distanceMeters,
            amount: amount,
            receiptNumber: receiptNumber,
            notes: notes,
            skipReason: skipReason,
            photoPathsJson: photoPathsJson,
            syncStatus: syncStatus,
            userId: userId,
            userName: userName,
            userRole: userRole,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String tripId,
            required String customerId,
            required String status,
            required DateTime timestamp,
            Value<double?> capturedLat = const Value.absent(),
            Value<double?> capturedLng = const Value.absent(),
            Value<double?> accuracyMeters = const Value.absent(),
            Value<double?> distanceMeters = const Value.absent(),
            Value<int> amount = const Value.absent(),
            Value<String?> receiptNumber = const Value.absent(),
            Value<String?> notes = const Value.absent(),
            Value<String?> skipReason = const Value.absent(),
            Value<String> photoPathsJson = const Value.absent(),
            Value<String> syncStatus = const Value.absent(),
            Value<String> userId = const Value.absent(),
            Value<String> userName = const Value.absent(),
            Value<String> userRole = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              VisitsCompanion.insert(
            id: id,
            tripId: tripId,
            customerId: customerId,
            status: status,
            timestamp: timestamp,
            capturedLat: capturedLat,
            capturedLng: capturedLng,
            accuracyMeters: accuracyMeters,
            distanceMeters: distanceMeters,
            amount: amount,
            receiptNumber: receiptNumber,
            notes: notes,
            skipReason: skipReason,
            photoPathsJson: photoPathsJson,
            syncStatus: syncStatus,
            userId: userId,
            userName: userName,
            userRole: userRole,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$VisitsTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: ({tripId = false, customerId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (tripId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.tripId,
                    referencedTable: $$VisitsTableReferences._tripIdTable(db),
                    referencedColumn:
                        $$VisitsTableReferences._tripIdTable(db).id,
                  ) as T;
                }
                if (customerId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.customerId,
                    referencedTable:
                        $$VisitsTableReferences._customerIdTable(db),
                    referencedColumn:
                        $$VisitsTableReferences._customerIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$VisitsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $VisitsTable,
    VisitsData,
    $$VisitsTableFilterComposer,
    $$VisitsTableOrderingComposer,
    $$VisitsTableAnnotationComposer,
    $$VisitsTableCreateCompanionBuilder,
    $$VisitsTableUpdateCompanionBuilder,
    (VisitsData, $$VisitsTableReferences),
    VisitsData,
    PrefetchHooks Function({bool tripId, bool customerId})>;
typedef $$AppConfigTableCreateCompanionBuilder = AppConfigCompanion Function({
  required String key,
  required String value,
  Value<int> rowid,
});
typedef $$AppConfigTableUpdateCompanionBuilder = AppConfigCompanion Function({
  Value<String> key,
  Value<String> value,
  Value<int> rowid,
});

class $$AppConfigTableFilterComposer
    extends Composer<_$AppDatabase, $AppConfigTable> {
  $$AppConfigTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnFilters(column));
}

class $$AppConfigTableOrderingComposer
    extends Composer<_$AppDatabase, $AppConfigTable> {
  $$AppConfigTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnOrderings(column));
}

class $$AppConfigTableAnnotationComposer
    extends Composer<_$AppDatabase, $AppConfigTable> {
  $$AppConfigTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$AppConfigTableTableManager extends RootTableManager<
    _$AppDatabase,
    $AppConfigTable,
    AppConfigData,
    $$AppConfigTableFilterComposer,
    $$AppConfigTableOrderingComposer,
    $$AppConfigTableAnnotationComposer,
    $$AppConfigTableCreateCompanionBuilder,
    $$AppConfigTableUpdateCompanionBuilder,
    (
      AppConfigData,
      BaseReferences<_$AppDatabase, $AppConfigTable, AppConfigData>
    ),
    AppConfigData,
    PrefetchHooks Function()> {
  $$AppConfigTableTableManager(_$AppDatabase db, $AppConfigTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AppConfigTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AppConfigTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AppConfigTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              AppConfigCompanion(
            key: key,
            value: value,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String key,
            required String value,
            Value<int> rowid = const Value.absent(),
          }) =>
              AppConfigCompanion.insert(
            key: key,
            value: value,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$AppConfigTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $AppConfigTable,
    AppConfigData,
    $$AppConfigTableFilterComposer,
    $$AppConfigTableOrderingComposer,
    $$AppConfigTableAnnotationComposer,
    $$AppConfigTableCreateCompanionBuilder,
    $$AppConfigTableUpdateCompanionBuilder,
    (
      AppConfigData,
      BaseReferences<_$AppDatabase, $AppConfigTable, AppConfigData>
    ),
    AppConfigData,
    PrefetchHooks Function()>;
typedef $$AuditLogsTableCreateCompanionBuilder = AuditLogsCompanion Function({
  required String id,
  required String entityType,
  required String entityId,
  required String action,
  required String actorId,
  required String actorName,
  required String actorRole,
  required DateTime timestamp,
  Value<String> diffJson,
  Value<String> summary,
  Value<String?> orgId,
  Value<int> rowid,
});
typedef $$AuditLogsTableUpdateCompanionBuilder = AuditLogsCompanion Function({
  Value<String> id,
  Value<String> entityType,
  Value<String> entityId,
  Value<String> action,
  Value<String> actorId,
  Value<String> actorName,
  Value<String> actorRole,
  Value<DateTime> timestamp,
  Value<String> diffJson,
  Value<String> summary,
  Value<String?> orgId,
  Value<int> rowid,
});

class $$AuditLogsTableFilterComposer
    extends Composer<_$AppDatabase, $AuditLogsTable> {
  $$AuditLogsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get entityType => $composableBuilder(
      column: $table.entityType, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get entityId => $composableBuilder(
      column: $table.entityId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get action => $composableBuilder(
      column: $table.action, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get actorId => $composableBuilder(
      column: $table.actorId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get actorName => $composableBuilder(
      column: $table.actorName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get actorRole => $composableBuilder(
      column: $table.actorRole, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get timestamp => $composableBuilder(
      column: $table.timestamp, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get diffJson => $composableBuilder(
      column: $table.diffJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get summary => $composableBuilder(
      column: $table.summary, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnFilters(column));
}

class $$AuditLogsTableOrderingComposer
    extends Composer<_$AppDatabase, $AuditLogsTable> {
  $$AuditLogsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get entityType => $composableBuilder(
      column: $table.entityType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get entityId => $composableBuilder(
      column: $table.entityId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get action => $composableBuilder(
      column: $table.action, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get actorId => $composableBuilder(
      column: $table.actorId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get actorName => $composableBuilder(
      column: $table.actorName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get actorRole => $composableBuilder(
      column: $table.actorRole, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get timestamp => $composableBuilder(
      column: $table.timestamp, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get diffJson => $composableBuilder(
      column: $table.diffJson, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get summary => $composableBuilder(
      column: $table.summary, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnOrderings(column));
}

class $$AuditLogsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AuditLogsTable> {
  $$AuditLogsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get entityType => $composableBuilder(
      column: $table.entityType, builder: (column) => column);

  GeneratedColumn<String> get entityId =>
      $composableBuilder(column: $table.entityId, builder: (column) => column);

  GeneratedColumn<String> get action =>
      $composableBuilder(column: $table.action, builder: (column) => column);

  GeneratedColumn<String> get actorId =>
      $composableBuilder(column: $table.actorId, builder: (column) => column);

  GeneratedColumn<String> get actorName =>
      $composableBuilder(column: $table.actorName, builder: (column) => column);

  GeneratedColumn<String> get actorRole =>
      $composableBuilder(column: $table.actorRole, builder: (column) => column);

  GeneratedColumn<DateTime> get timestamp =>
      $composableBuilder(column: $table.timestamp, builder: (column) => column);

  GeneratedColumn<String> get diffJson =>
      $composableBuilder(column: $table.diffJson, builder: (column) => column);

  GeneratedColumn<String> get summary =>
      $composableBuilder(column: $table.summary, builder: (column) => column);

  GeneratedColumn<String> get orgId =>
      $composableBuilder(column: $table.orgId, builder: (column) => column);
}

class $$AuditLogsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $AuditLogsTable,
    AuditLogData,
    $$AuditLogsTableFilterComposer,
    $$AuditLogsTableOrderingComposer,
    $$AuditLogsTableAnnotationComposer,
    $$AuditLogsTableCreateCompanionBuilder,
    $$AuditLogsTableUpdateCompanionBuilder,
    (
      AuditLogData,
      BaseReferences<_$AppDatabase, $AuditLogsTable, AuditLogData>
    ),
    AuditLogData,
    PrefetchHooks Function()> {
  $$AuditLogsTableTableManager(_$AppDatabase db, $AuditLogsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AuditLogsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AuditLogsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AuditLogsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> entityType = const Value.absent(),
            Value<String> entityId = const Value.absent(),
            Value<String> action = const Value.absent(),
            Value<String> actorId = const Value.absent(),
            Value<String> actorName = const Value.absent(),
            Value<String> actorRole = const Value.absent(),
            Value<DateTime> timestamp = const Value.absent(),
            Value<String> diffJson = const Value.absent(),
            Value<String> summary = const Value.absent(),
            Value<String?> orgId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              AuditLogsCompanion(
            id: id,
            entityType: entityType,
            entityId: entityId,
            action: action,
            actorId: actorId,
            actorName: actorName,
            actorRole: actorRole,
            timestamp: timestamp,
            diffJson: diffJson,
            summary: summary,
            orgId: orgId,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String entityType,
            required String entityId,
            required String action,
            required String actorId,
            required String actorName,
            required String actorRole,
            required DateTime timestamp,
            Value<String> diffJson = const Value.absent(),
            Value<String> summary = const Value.absent(),
            Value<String?> orgId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              AuditLogsCompanion.insert(
            id: id,
            entityType: entityType,
            entityId: entityId,
            action: action,
            actorId: actorId,
            actorName: actorName,
            actorRole: actorRole,
            timestamp: timestamp,
            diffJson: diffJson,
            summary: summary,
            orgId: orgId,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$AuditLogsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $AuditLogsTable,
    AuditLogData,
    $$AuditLogsTableFilterComposer,
    $$AuditLogsTableOrderingComposer,
    $$AuditLogsTableAnnotationComposer,
    $$AuditLogsTableCreateCompanionBuilder,
    $$AuditLogsTableUpdateCompanionBuilder,
    (
      AuditLogData,
      BaseReferences<_$AppDatabase, $AuditLogsTable, AuditLogData>
    ),
    AuditLogData,
    PrefetchHooks Function()>;
typedef $$UsersTableCreateCompanionBuilder = UsersCompanion Function({
  required String id,
  required String name,
  required String email,
  Value<String> phone,
  required String role,
  Value<bool> isActive,
  Value<String> passwordHash,
  Value<String> passwordSalt,
  required DateTime createdAt,
  Value<DateTime?> updatedAt,
  Value<bool> passwordTemporary,
  Value<String?> orgId,
  Value<String?> fcmToken,
  Value<int> rowid,
});
typedef $$UsersTableUpdateCompanionBuilder = UsersCompanion Function({
  Value<String> id,
  Value<String> name,
  Value<String> email,
  Value<String> phone,
  Value<String> role,
  Value<bool> isActive,
  Value<String> passwordHash,
  Value<String> passwordSalt,
  Value<DateTime> createdAt,
  Value<DateTime?> updatedAt,
  Value<bool> passwordTemporary,
  Value<String?> orgId,
  Value<String?> fcmToken,
  Value<int> rowid,
});

class $$UsersTableFilterComposer extends Composer<_$AppDatabase, $UsersTable> {
  $$UsersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get email => $composableBuilder(
      column: $table.email, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get phone => $composableBuilder(
      column: $table.phone, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get role => $composableBuilder(
      column: $table.role, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isActive => $composableBuilder(
      column: $table.isActive, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get passwordHash => $composableBuilder(
      column: $table.passwordHash, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get passwordSalt => $composableBuilder(
      column: $table.passwordSalt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get passwordTemporary => $composableBuilder(
      column: $table.passwordTemporary,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get fcmToken => $composableBuilder(
      column: $table.fcmToken, builder: (column) => ColumnFilters(column));
}

class $$UsersTableOrderingComposer
    extends Composer<_$AppDatabase, $UsersTable> {
  $$UsersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get email => $composableBuilder(
      column: $table.email, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get phone => $composableBuilder(
      column: $table.phone, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get role => $composableBuilder(
      column: $table.role, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isActive => $composableBuilder(
      column: $table.isActive, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get passwordHash => $composableBuilder(
      column: $table.passwordHash,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get passwordSalt => $composableBuilder(
      column: $table.passwordSalt,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get passwordTemporary => $composableBuilder(
      column: $table.passwordTemporary,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get fcmToken => $composableBuilder(
      column: $table.fcmToken, builder: (column) => ColumnOrderings(column));
}

class $$UsersTableAnnotationComposer
    extends Composer<_$AppDatabase, $UsersTable> {
  $$UsersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get email =>
      $composableBuilder(column: $table.email, builder: (column) => column);

  GeneratedColumn<String> get phone =>
      $composableBuilder(column: $table.phone, builder: (column) => column);

  GeneratedColumn<String> get role =>
      $composableBuilder(column: $table.role, builder: (column) => column);

  GeneratedColumn<bool> get isActive =>
      $composableBuilder(column: $table.isActive, builder: (column) => column);

  GeneratedColumn<String> get passwordHash => $composableBuilder(
      column: $table.passwordHash, builder: (column) => column);

  GeneratedColumn<String> get passwordSalt => $composableBuilder(
      column: $table.passwordSalt, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<bool> get passwordTemporary => $composableBuilder(
      column: $table.passwordTemporary, builder: (column) => column);

  GeneratedColumn<String> get orgId =>
      $composableBuilder(column: $table.orgId, builder: (column) => column);

  GeneratedColumn<String> get fcmToken =>
      $composableBuilder(column: $table.fcmToken, builder: (column) => column);
}

class $$UsersTableTableManager extends RootTableManager<
    _$AppDatabase,
    $UsersTable,
    UsersData,
    $$UsersTableFilterComposer,
    $$UsersTableOrderingComposer,
    $$UsersTableAnnotationComposer,
    $$UsersTableCreateCompanionBuilder,
    $$UsersTableUpdateCompanionBuilder,
    (UsersData, BaseReferences<_$AppDatabase, $UsersTable, UsersData>),
    UsersData,
    PrefetchHooks Function()> {
  $$UsersTableTableManager(_$AppDatabase db, $UsersTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$UsersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$UsersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$UsersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<String> email = const Value.absent(),
            Value<String> phone = const Value.absent(),
            Value<String> role = const Value.absent(),
            Value<bool> isActive = const Value.absent(),
            Value<String> passwordHash = const Value.absent(),
            Value<String> passwordSalt = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
            Value<bool> passwordTemporary = const Value.absent(),
            Value<String?> orgId = const Value.absent(),
            Value<String?> fcmToken = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              UsersCompanion(
            id: id,
            name: name,
            email: email,
            phone: phone,
            role: role,
            isActive: isActive,
            passwordHash: passwordHash,
            passwordSalt: passwordSalt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            passwordTemporary: passwordTemporary,
            orgId: orgId,
            fcmToken: fcmToken,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String name,
            required String email,
            Value<String> phone = const Value.absent(),
            required String role,
            Value<bool> isActive = const Value.absent(),
            Value<String> passwordHash = const Value.absent(),
            Value<String> passwordSalt = const Value.absent(),
            required DateTime createdAt,
            Value<DateTime?> updatedAt = const Value.absent(),
            Value<bool> passwordTemporary = const Value.absent(),
            Value<String?> orgId = const Value.absent(),
            Value<String?> fcmToken = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              UsersCompanion.insert(
            id: id,
            name: name,
            email: email,
            phone: phone,
            role: role,
            isActive: isActive,
            passwordHash: passwordHash,
            passwordSalt: passwordSalt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            passwordTemporary: passwordTemporary,
            orgId: orgId,
            fcmToken: fcmToken,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$UsersTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $UsersTable,
    UsersData,
    $$UsersTableFilterComposer,
    $$UsersTableOrderingComposer,
    $$UsersTableAnnotationComposer,
    $$UsersTableCreateCompanionBuilder,
    $$UsersTableUpdateCompanionBuilder,
    (UsersData, BaseReferences<_$AppDatabase, $UsersTable, UsersData>),
    UsersData,
    PrefetchHooks Function()>;
typedef $$RouteAssignmentsTableCreateCompanionBuilder
    = RouteAssignmentsCompanion Function({
  required String userId,
  required String routeId,
  required DateTime assignedAt,
  Value<String> assignedBy,
  Value<int> rowid,
});
typedef $$RouteAssignmentsTableUpdateCompanionBuilder
    = RouteAssignmentsCompanion Function({
  Value<String> userId,
  Value<String> routeId,
  Value<DateTime> assignedAt,
  Value<String> assignedBy,
  Value<int> rowid,
});

class $$RouteAssignmentsTableFilterComposer
    extends Composer<_$AppDatabase, $RouteAssignmentsTable> {
  $$RouteAssignmentsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get userId => $composableBuilder(
      column: $table.userId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get routeId => $composableBuilder(
      column: $table.routeId, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get assignedAt => $composableBuilder(
      column: $table.assignedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get assignedBy => $composableBuilder(
      column: $table.assignedBy, builder: (column) => ColumnFilters(column));
}

class $$RouteAssignmentsTableOrderingComposer
    extends Composer<_$AppDatabase, $RouteAssignmentsTable> {
  $$RouteAssignmentsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get userId => $composableBuilder(
      column: $table.userId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get routeId => $composableBuilder(
      column: $table.routeId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get assignedAt => $composableBuilder(
      column: $table.assignedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get assignedBy => $composableBuilder(
      column: $table.assignedBy, builder: (column) => ColumnOrderings(column));
}

class $$RouteAssignmentsTableAnnotationComposer
    extends Composer<_$AppDatabase, $RouteAssignmentsTable> {
  $$RouteAssignmentsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get routeId =>
      $composableBuilder(column: $table.routeId, builder: (column) => column);

  GeneratedColumn<DateTime> get assignedAt => $composableBuilder(
      column: $table.assignedAt, builder: (column) => column);

  GeneratedColumn<String> get assignedBy => $composableBuilder(
      column: $table.assignedBy, builder: (column) => column);
}

class $$RouteAssignmentsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $RouteAssignmentsTable,
    RouteAssignmentsData,
    $$RouteAssignmentsTableFilterComposer,
    $$RouteAssignmentsTableOrderingComposer,
    $$RouteAssignmentsTableAnnotationComposer,
    $$RouteAssignmentsTableCreateCompanionBuilder,
    $$RouteAssignmentsTableUpdateCompanionBuilder,
    (
      RouteAssignmentsData,
      BaseReferences<_$AppDatabase, $RouteAssignmentsTable,
          RouteAssignmentsData>
    ),
    RouteAssignmentsData,
    PrefetchHooks Function()> {
  $$RouteAssignmentsTableTableManager(
      _$AppDatabase db, $RouteAssignmentsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RouteAssignmentsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RouteAssignmentsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RouteAssignmentsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> userId = const Value.absent(),
            Value<String> routeId = const Value.absent(),
            Value<DateTime> assignedAt = const Value.absent(),
            Value<String> assignedBy = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              RouteAssignmentsCompanion(
            userId: userId,
            routeId: routeId,
            assignedAt: assignedAt,
            assignedBy: assignedBy,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String userId,
            required String routeId,
            required DateTime assignedAt,
            Value<String> assignedBy = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              RouteAssignmentsCompanion.insert(
            userId: userId,
            routeId: routeId,
            assignedAt: assignedAt,
            assignedBy: assignedBy,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$RouteAssignmentsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $RouteAssignmentsTable,
    RouteAssignmentsData,
    $$RouteAssignmentsTableFilterComposer,
    $$RouteAssignmentsTableOrderingComposer,
    $$RouteAssignmentsTableAnnotationComposer,
    $$RouteAssignmentsTableCreateCompanionBuilder,
    $$RouteAssignmentsTableUpdateCompanionBuilder,
    (
      RouteAssignmentsData,
      BaseReferences<_$AppDatabase, $RouteAssignmentsTable,
          RouteAssignmentsData>
    ),
    RouteAssignmentsData,
    PrefetchHooks Function()>;
typedef $$UploadQueueTableCreateCompanionBuilder = UploadQueueCompanion
    Function({
  required String id,
  required String localPath,
  required String remotePath,
  required String bucket,
  Value<String> status,
  Value<int> retryCount,
  Value<String?> lastError,
  required String entityType,
  required String entityId,
  required DateTime createdAt,
  required DateTime updatedAt,
  Value<int> rowid,
});
typedef $$UploadQueueTableUpdateCompanionBuilder = UploadQueueCompanion
    Function({
  Value<String> id,
  Value<String> localPath,
  Value<String> remotePath,
  Value<String> bucket,
  Value<String> status,
  Value<int> retryCount,
  Value<String?> lastError,
  Value<String> entityType,
  Value<String> entityId,
  Value<DateTime> createdAt,
  Value<DateTime> updatedAt,
  Value<int> rowid,
});

class $$UploadQueueTableFilterComposer
    extends Composer<_$AppDatabase, $UploadQueueTable> {
  $$UploadQueueTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get localPath => $composableBuilder(
      column: $table.localPath, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get remotePath => $composableBuilder(
      column: $table.remotePath, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get bucket => $composableBuilder(
      column: $table.bucket, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get retryCount => $composableBuilder(
      column: $table.retryCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get lastError => $composableBuilder(
      column: $table.lastError, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get entityType => $composableBuilder(
      column: $table.entityType, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get entityId => $composableBuilder(
      column: $table.entityId, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$UploadQueueTableOrderingComposer
    extends Composer<_$AppDatabase, $UploadQueueTable> {
  $$UploadQueueTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get localPath => $composableBuilder(
      column: $table.localPath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get remotePath => $composableBuilder(
      column: $table.remotePath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get bucket => $composableBuilder(
      column: $table.bucket, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get retryCount => $composableBuilder(
      column: $table.retryCount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get lastError => $composableBuilder(
      column: $table.lastError, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get entityType => $composableBuilder(
      column: $table.entityType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get entityId => $composableBuilder(
      column: $table.entityId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$UploadQueueTableAnnotationComposer
    extends Composer<_$AppDatabase, $UploadQueueTable> {
  $$UploadQueueTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get localPath =>
      $composableBuilder(column: $table.localPath, builder: (column) => column);

  GeneratedColumn<String> get remotePath => $composableBuilder(
      column: $table.remotePath, builder: (column) => column);

  GeneratedColumn<String> get bucket =>
      $composableBuilder(column: $table.bucket, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get retryCount => $composableBuilder(
      column: $table.retryCount, builder: (column) => column);

  GeneratedColumn<String> get lastError =>
      $composableBuilder(column: $table.lastError, builder: (column) => column);

  GeneratedColumn<String> get entityType => $composableBuilder(
      column: $table.entityType, builder: (column) => column);

  GeneratedColumn<String> get entityId =>
      $composableBuilder(column: $table.entityId, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$UploadQueueTableTableManager extends RootTableManager<
    _$AppDatabase,
    $UploadQueueTable,
    UploadQueueData,
    $$UploadQueueTableFilterComposer,
    $$UploadQueueTableOrderingComposer,
    $$UploadQueueTableAnnotationComposer,
    $$UploadQueueTableCreateCompanionBuilder,
    $$UploadQueueTableUpdateCompanionBuilder,
    (
      UploadQueueData,
      BaseReferences<_$AppDatabase, $UploadQueueTable, UploadQueueData>
    ),
    UploadQueueData,
    PrefetchHooks Function()> {
  $$UploadQueueTableTableManager(_$AppDatabase db, $UploadQueueTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$UploadQueueTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$UploadQueueTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$UploadQueueTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> localPath = const Value.absent(),
            Value<String> remotePath = const Value.absent(),
            Value<String> bucket = const Value.absent(),
            Value<String> status = const Value.absent(),
            Value<int> retryCount = const Value.absent(),
            Value<String?> lastError = const Value.absent(),
            Value<String> entityType = const Value.absent(),
            Value<String> entityId = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              UploadQueueCompanion(
            id: id,
            localPath: localPath,
            remotePath: remotePath,
            bucket: bucket,
            status: status,
            retryCount: retryCount,
            lastError: lastError,
            entityType: entityType,
            entityId: entityId,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String localPath,
            required String remotePath,
            required String bucket,
            Value<String> status = const Value.absent(),
            Value<int> retryCount = const Value.absent(),
            Value<String?> lastError = const Value.absent(),
            required String entityType,
            required String entityId,
            required DateTime createdAt,
            required DateTime updatedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              UploadQueueCompanion.insert(
            id: id,
            localPath: localPath,
            remotePath: remotePath,
            bucket: bucket,
            status: status,
            retryCount: retryCount,
            lastError: lastError,
            entityType: entityType,
            entityId: entityId,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$UploadQueueTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $UploadQueueTable,
    UploadQueueData,
    $$UploadQueueTableFilterComposer,
    $$UploadQueueTableOrderingComposer,
    $$UploadQueueTableAnnotationComposer,
    $$UploadQueueTableCreateCompanionBuilder,
    $$UploadQueueTableUpdateCompanionBuilder,
    (
      UploadQueueData,
      BaseReferences<_$AppDatabase, $UploadQueueTable, UploadQueueData>
    ),
    UploadQueueData,
    PrefetchHooks Function()>;
typedef $$DeliveriesTableCreateCompanionBuilder = DeliveriesCompanion Function({
  required String id,
  Value<String?> driverId,
  Value<String?> driverName,
  Value<String?> driverRole,
  required String createdBy,
  Value<String> createdByName,
  Value<String> createdByRole,
  required DateTime createdAt,
  Value<DateTime?> startedAt,
  Value<DateTime?> completedAt,
  Value<String> status,
  Value<String?> notes,
  Value<String?> orgId,
  Value<int> rowid,
});
typedef $$DeliveriesTableUpdateCompanionBuilder = DeliveriesCompanion Function({
  Value<String> id,
  Value<String?> driverId,
  Value<String?> driverName,
  Value<String?> driverRole,
  Value<String> createdBy,
  Value<String> createdByName,
  Value<String> createdByRole,
  Value<DateTime> createdAt,
  Value<DateTime?> startedAt,
  Value<DateTime?> completedAt,
  Value<String> status,
  Value<String?> notes,
  Value<String?> orgId,
  Value<int> rowid,
});

class $$DeliveriesTableFilterComposer
    extends Composer<_$AppDatabase, $DeliveriesTable> {
  $$DeliveriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get driverId => $composableBuilder(
      column: $table.driverId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get driverName => $composableBuilder(
      column: $table.driverName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get driverRole => $composableBuilder(
      column: $table.driverRole, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get createdBy => $composableBuilder(
      column: $table.createdBy, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get createdByName => $composableBuilder(
      column: $table.createdByName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get createdByRole => $composableBuilder(
      column: $table.createdByRole, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get startedAt => $composableBuilder(
      column: $table.startedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get completedAt => $composableBuilder(
      column: $table.completedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get notes => $composableBuilder(
      column: $table.notes, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnFilters(column));
}

class $$DeliveriesTableOrderingComposer
    extends Composer<_$AppDatabase, $DeliveriesTable> {
  $$DeliveriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get driverId => $composableBuilder(
      column: $table.driverId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get driverName => $composableBuilder(
      column: $table.driverName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get driverRole => $composableBuilder(
      column: $table.driverRole, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get createdBy => $composableBuilder(
      column: $table.createdBy, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get createdByName => $composableBuilder(
      column: $table.createdByName,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get createdByRole => $composableBuilder(
      column: $table.createdByRole,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get startedAt => $composableBuilder(
      column: $table.startedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get completedAt => $composableBuilder(
      column: $table.completedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get notes => $composableBuilder(
      column: $table.notes, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnOrderings(column));
}

class $$DeliveriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $DeliveriesTable> {
  $$DeliveriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get driverId =>
      $composableBuilder(column: $table.driverId, builder: (column) => column);

  GeneratedColumn<String> get driverName => $composableBuilder(
      column: $table.driverName, builder: (column) => column);

  GeneratedColumn<String> get driverRole => $composableBuilder(
      column: $table.driverRole, builder: (column) => column);

  GeneratedColumn<String> get createdBy =>
      $composableBuilder(column: $table.createdBy, builder: (column) => column);

  GeneratedColumn<String> get createdByName => $composableBuilder(
      column: $table.createdByName, builder: (column) => column);

  GeneratedColumn<String> get createdByRole => $composableBuilder(
      column: $table.createdByRole, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get startedAt =>
      $composableBuilder(column: $table.startedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get completedAt => $composableBuilder(
      column: $table.completedAt, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<String> get orgId =>
      $composableBuilder(column: $table.orgId, builder: (column) => column);
}

class $$DeliveriesTableTableManager extends RootTableManager<
    _$AppDatabase,
    $DeliveriesTable,
    DeliveriesData,
    $$DeliveriesTableFilterComposer,
    $$DeliveriesTableOrderingComposer,
    $$DeliveriesTableAnnotationComposer,
    $$DeliveriesTableCreateCompanionBuilder,
    $$DeliveriesTableUpdateCompanionBuilder,
    (
      DeliveriesData,
      BaseReferences<_$AppDatabase, $DeliveriesTable, DeliveriesData>
    ),
    DeliveriesData,
    PrefetchHooks Function()> {
  $$DeliveriesTableTableManager(_$AppDatabase db, $DeliveriesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DeliveriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DeliveriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DeliveriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String?> driverId = const Value.absent(),
            Value<String?> driverName = const Value.absent(),
            Value<String?> driverRole = const Value.absent(),
            Value<String> createdBy = const Value.absent(),
            Value<String> createdByName = const Value.absent(),
            Value<String> createdByRole = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime?> startedAt = const Value.absent(),
            Value<DateTime?> completedAt = const Value.absent(),
            Value<String> status = const Value.absent(),
            Value<String?> notes = const Value.absent(),
            Value<String?> orgId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              DeliveriesCompanion(
            id: id,
            driverId: driverId,
            driverName: driverName,
            driverRole: driverRole,
            createdBy: createdBy,
            createdByName: createdByName,
            createdByRole: createdByRole,
            createdAt: createdAt,
            startedAt: startedAt,
            completedAt: completedAt,
            status: status,
            notes: notes,
            orgId: orgId,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            Value<String?> driverId = const Value.absent(),
            Value<String?> driverName = const Value.absent(),
            Value<String?> driverRole = const Value.absent(),
            required String createdBy,
            Value<String> createdByName = const Value.absent(),
            Value<String> createdByRole = const Value.absent(),
            required DateTime createdAt,
            Value<DateTime?> startedAt = const Value.absent(),
            Value<DateTime?> completedAt = const Value.absent(),
            Value<String> status = const Value.absent(),
            Value<String?> notes = const Value.absent(),
            Value<String?> orgId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              DeliveriesCompanion.insert(
            id: id,
            driverId: driverId,
            driverName: driverName,
            driverRole: driverRole,
            createdBy: createdBy,
            createdByName: createdByName,
            createdByRole: createdByRole,
            createdAt: createdAt,
            startedAt: startedAt,
            completedAt: completedAt,
            status: status,
            notes: notes,
            orgId: orgId,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$DeliveriesTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $DeliveriesTable,
    DeliveriesData,
    $$DeliveriesTableFilterComposer,
    $$DeliveriesTableOrderingComposer,
    $$DeliveriesTableAnnotationComposer,
    $$DeliveriesTableCreateCompanionBuilder,
    $$DeliveriesTableUpdateCompanionBuilder,
    (
      DeliveriesData,
      BaseReferences<_$AppDatabase, $DeliveriesTable, DeliveriesData>
    ),
    DeliveriesData,
    PrefetchHooks Function()>;
typedef $$DeliveryStopsTableCreateCompanionBuilder = DeliveryStopsCompanion
    Function({
  required String id,
  required String deliveryId,
  required String customerId,
  Value<String> customerCode,
  Value<String> customerName,
  required int sequence,
  Value<String> itemDescription,
  Value<int> amount,
  Value<String> paymentType,
  Value<String> status,
  Value<DateTime?> deliveredAt,
  Value<String?> failureReason,
  Value<int?> cashReceived,
  Value<double?> capturedLat,
  Value<double?> capturedLng,
  Value<int?> distanceMeters,
  Value<String> verification,
  Value<String> syncStatus,
  Value<String?> driverNote,
  Value<String?> soInvoiceNumber,
  Value<String?> doId,
  Value<String> photoPathsJson,
  Value<int> rowid,
});
typedef $$DeliveryStopsTableUpdateCompanionBuilder = DeliveryStopsCompanion
    Function({
  Value<String> id,
  Value<String> deliveryId,
  Value<String> customerId,
  Value<String> customerCode,
  Value<String> customerName,
  Value<int> sequence,
  Value<String> itemDescription,
  Value<int> amount,
  Value<String> paymentType,
  Value<String> status,
  Value<DateTime?> deliveredAt,
  Value<String?> failureReason,
  Value<int?> cashReceived,
  Value<double?> capturedLat,
  Value<double?> capturedLng,
  Value<int?> distanceMeters,
  Value<String> verification,
  Value<String> syncStatus,
  Value<String?> driverNote,
  Value<String?> soInvoiceNumber,
  Value<String?> doId,
  Value<String> photoPathsJson,
  Value<int> rowid,
});

class $$DeliveryStopsTableFilterComposer
    extends Composer<_$AppDatabase, $DeliveryStopsTable> {
  $$DeliveryStopsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get deliveryId => $composableBuilder(
      column: $table.deliveryId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get customerId => $composableBuilder(
      column: $table.customerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get customerCode => $composableBuilder(
      column: $table.customerCode, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get customerName => $composableBuilder(
      column: $table.customerName, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sequence => $composableBuilder(
      column: $table.sequence, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get itemDescription => $composableBuilder(
      column: $table.itemDescription,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get amount => $composableBuilder(
      column: $table.amount, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get paymentType => $composableBuilder(
      column: $table.paymentType, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get deliveredAt => $composableBuilder(
      column: $table.deliveredAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get failureReason => $composableBuilder(
      column: $table.failureReason, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get cashReceived => $composableBuilder(
      column: $table.cashReceived, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get capturedLat => $composableBuilder(
      column: $table.capturedLat, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get capturedLng => $composableBuilder(
      column: $table.capturedLng, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get distanceMeters => $composableBuilder(
      column: $table.distanceMeters,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get verification => $composableBuilder(
      column: $table.verification, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get driverNote => $composableBuilder(
      column: $table.driverNote, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get soInvoiceNumber => $composableBuilder(
      column: $table.soInvoiceNumber,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get doId => $composableBuilder(
      column: $table.doId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get photoPathsJson => $composableBuilder(
      column: $table.photoPathsJson,
      builder: (column) => ColumnFilters(column));
}

class $$DeliveryStopsTableOrderingComposer
    extends Composer<_$AppDatabase, $DeliveryStopsTable> {
  $$DeliveryStopsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get deliveryId => $composableBuilder(
      column: $table.deliveryId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get customerId => $composableBuilder(
      column: $table.customerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get customerCode => $composableBuilder(
      column: $table.customerCode,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get customerName => $composableBuilder(
      column: $table.customerName,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sequence => $composableBuilder(
      column: $table.sequence, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get itemDescription => $composableBuilder(
      column: $table.itemDescription,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get amount => $composableBuilder(
      column: $table.amount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get paymentType => $composableBuilder(
      column: $table.paymentType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get deliveredAt => $composableBuilder(
      column: $table.deliveredAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get failureReason => $composableBuilder(
      column: $table.failureReason,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get cashReceived => $composableBuilder(
      column: $table.cashReceived,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get capturedLat => $composableBuilder(
      column: $table.capturedLat, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get capturedLng => $composableBuilder(
      column: $table.capturedLng, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get distanceMeters => $composableBuilder(
      column: $table.distanceMeters,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get verification => $composableBuilder(
      column: $table.verification,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get driverNote => $composableBuilder(
      column: $table.driverNote, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get soInvoiceNumber => $composableBuilder(
      column: $table.soInvoiceNumber,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get doId => $composableBuilder(
      column: $table.doId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get photoPathsJson => $composableBuilder(
      column: $table.photoPathsJson,
      builder: (column) => ColumnOrderings(column));
}

class $$DeliveryStopsTableAnnotationComposer
    extends Composer<_$AppDatabase, $DeliveryStopsTable> {
  $$DeliveryStopsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get deliveryId => $composableBuilder(
      column: $table.deliveryId, builder: (column) => column);

  GeneratedColumn<String> get customerId => $composableBuilder(
      column: $table.customerId, builder: (column) => column);

  GeneratedColumn<String> get customerCode => $composableBuilder(
      column: $table.customerCode, builder: (column) => column);

  GeneratedColumn<String> get customerName => $composableBuilder(
      column: $table.customerName, builder: (column) => column);

  GeneratedColumn<int> get sequence =>
      $composableBuilder(column: $table.sequence, builder: (column) => column);

  GeneratedColumn<String> get itemDescription => $composableBuilder(
      column: $table.itemDescription, builder: (column) => column);

  GeneratedColumn<int> get amount =>
      $composableBuilder(column: $table.amount, builder: (column) => column);

  GeneratedColumn<String> get paymentType => $composableBuilder(
      column: $table.paymentType, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<DateTime> get deliveredAt => $composableBuilder(
      column: $table.deliveredAt, builder: (column) => column);

  GeneratedColumn<String> get failureReason => $composableBuilder(
      column: $table.failureReason, builder: (column) => column);

  GeneratedColumn<int> get cashReceived => $composableBuilder(
      column: $table.cashReceived, builder: (column) => column);

  GeneratedColumn<double> get capturedLat => $composableBuilder(
      column: $table.capturedLat, builder: (column) => column);

  GeneratedColumn<double> get capturedLng => $composableBuilder(
      column: $table.capturedLng, builder: (column) => column);

  GeneratedColumn<int> get distanceMeters => $composableBuilder(
      column: $table.distanceMeters, builder: (column) => column);

  GeneratedColumn<String> get verification => $composableBuilder(
      column: $table.verification, builder: (column) => column);

  GeneratedColumn<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => column);

  GeneratedColumn<String> get driverNote => $composableBuilder(
      column: $table.driverNote, builder: (column) => column);

  GeneratedColumn<String> get soInvoiceNumber => $composableBuilder(
      column: $table.soInvoiceNumber, builder: (column) => column);

  GeneratedColumn<String> get doId =>
      $composableBuilder(column: $table.doId, builder: (column) => column);

  GeneratedColumn<String> get photoPathsJson => $composableBuilder(
      column: $table.photoPathsJson, builder: (column) => column);
}

class $$DeliveryStopsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $DeliveryStopsTable,
    DeliveryStopsData,
    $$DeliveryStopsTableFilterComposer,
    $$DeliveryStopsTableOrderingComposer,
    $$DeliveryStopsTableAnnotationComposer,
    $$DeliveryStopsTableCreateCompanionBuilder,
    $$DeliveryStopsTableUpdateCompanionBuilder,
    (
      DeliveryStopsData,
      BaseReferences<_$AppDatabase, $DeliveryStopsTable, DeliveryStopsData>
    ),
    DeliveryStopsData,
    PrefetchHooks Function()> {
  $$DeliveryStopsTableTableManager(_$AppDatabase db, $DeliveryStopsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DeliveryStopsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DeliveryStopsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DeliveryStopsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> deliveryId = const Value.absent(),
            Value<String> customerId = const Value.absent(),
            Value<String> customerCode = const Value.absent(),
            Value<String> customerName = const Value.absent(),
            Value<int> sequence = const Value.absent(),
            Value<String> itemDescription = const Value.absent(),
            Value<int> amount = const Value.absent(),
            Value<String> paymentType = const Value.absent(),
            Value<String> status = const Value.absent(),
            Value<DateTime?> deliveredAt = const Value.absent(),
            Value<String?> failureReason = const Value.absent(),
            Value<int?> cashReceived = const Value.absent(),
            Value<double?> capturedLat = const Value.absent(),
            Value<double?> capturedLng = const Value.absent(),
            Value<int?> distanceMeters = const Value.absent(),
            Value<String> verification = const Value.absent(),
            Value<String> syncStatus = const Value.absent(),
            Value<String?> driverNote = const Value.absent(),
            Value<String?> soInvoiceNumber = const Value.absent(),
            Value<String?> doId = const Value.absent(),
            Value<String> photoPathsJson = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              DeliveryStopsCompanion(
            id: id,
            deliveryId: deliveryId,
            customerId: customerId,
            customerCode: customerCode,
            customerName: customerName,
            sequence: sequence,
            itemDescription: itemDescription,
            amount: amount,
            paymentType: paymentType,
            status: status,
            deliveredAt: deliveredAt,
            failureReason: failureReason,
            cashReceived: cashReceived,
            capturedLat: capturedLat,
            capturedLng: capturedLng,
            distanceMeters: distanceMeters,
            verification: verification,
            syncStatus: syncStatus,
            driverNote: driverNote,
            soInvoiceNumber: soInvoiceNumber,
            doId: doId,
            photoPathsJson: photoPathsJson,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String deliveryId,
            required String customerId,
            Value<String> customerCode = const Value.absent(),
            Value<String> customerName = const Value.absent(),
            required int sequence,
            Value<String> itemDescription = const Value.absent(),
            Value<int> amount = const Value.absent(),
            Value<String> paymentType = const Value.absent(),
            Value<String> status = const Value.absent(),
            Value<DateTime?> deliveredAt = const Value.absent(),
            Value<String?> failureReason = const Value.absent(),
            Value<int?> cashReceived = const Value.absent(),
            Value<double?> capturedLat = const Value.absent(),
            Value<double?> capturedLng = const Value.absent(),
            Value<int?> distanceMeters = const Value.absent(),
            Value<String> verification = const Value.absent(),
            Value<String> syncStatus = const Value.absent(),
            Value<String?> driverNote = const Value.absent(),
            Value<String?> soInvoiceNumber = const Value.absent(),
            Value<String?> doId = const Value.absent(),
            Value<String> photoPathsJson = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              DeliveryStopsCompanion.insert(
            id: id,
            deliveryId: deliveryId,
            customerId: customerId,
            customerCode: customerCode,
            customerName: customerName,
            sequence: sequence,
            itemDescription: itemDescription,
            amount: amount,
            paymentType: paymentType,
            status: status,
            deliveredAt: deliveredAt,
            failureReason: failureReason,
            cashReceived: cashReceived,
            capturedLat: capturedLat,
            capturedLng: capturedLng,
            distanceMeters: distanceMeters,
            verification: verification,
            syncStatus: syncStatus,
            driverNote: driverNote,
            soInvoiceNumber: soInvoiceNumber,
            doId: doId,
            photoPathsJson: photoPathsJson,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$DeliveryStopsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $DeliveryStopsTable,
    DeliveryStopsData,
    $$DeliveryStopsTableFilterComposer,
    $$DeliveryStopsTableOrderingComposer,
    $$DeliveryStopsTableAnnotationComposer,
    $$DeliveryStopsTableCreateCompanionBuilder,
    $$DeliveryStopsTableUpdateCompanionBuilder,
    (
      DeliveryStopsData,
      BaseReferences<_$AppDatabase, $DeliveryStopsTable, DeliveryStopsData>
    ),
    DeliveryStopsData,
    PrefetchHooks Function()>;
typedef $$OrgsTableCreateCompanionBuilder = OrgsCompanion Function({
  required String id,
  required String name,
  Value<String?> masterAdminId,
  Value<bool> isActive,
  required DateTime createdAt,
  Value<DateTime?> updatedAt,
  Value<int> rowid,
});
typedef $$OrgsTableUpdateCompanionBuilder = OrgsCompanion Function({
  Value<String> id,
  Value<String> name,
  Value<String?> masterAdminId,
  Value<bool> isActive,
  Value<DateTime> createdAt,
  Value<DateTime?> updatedAt,
  Value<int> rowid,
});

class $$OrgsTableFilterComposer extends Composer<_$AppDatabase, $OrgsTable> {
  $$OrgsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get masterAdminId => $composableBuilder(
      column: $table.masterAdminId, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isActive => $composableBuilder(
      column: $table.isActive, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$OrgsTableOrderingComposer extends Composer<_$AppDatabase, $OrgsTable> {
  $$OrgsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get masterAdminId => $composableBuilder(
      column: $table.masterAdminId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isActive => $composableBuilder(
      column: $table.isActive, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$OrgsTableAnnotationComposer
    extends Composer<_$AppDatabase, $OrgsTable> {
  $$OrgsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get masterAdminId => $composableBuilder(
      column: $table.masterAdminId, builder: (column) => column);

  GeneratedColumn<bool> get isActive =>
      $composableBuilder(column: $table.isActive, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$OrgsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $OrgsTable,
    OrgsData,
    $$OrgsTableFilterComposer,
    $$OrgsTableOrderingComposer,
    $$OrgsTableAnnotationComposer,
    $$OrgsTableCreateCompanionBuilder,
    $$OrgsTableUpdateCompanionBuilder,
    (OrgsData, BaseReferences<_$AppDatabase, $OrgsTable, OrgsData>),
    OrgsData,
    PrefetchHooks Function()> {
  $$OrgsTableTableManager(_$AppDatabase db, $OrgsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$OrgsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$OrgsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$OrgsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<String?> masterAdminId = const Value.absent(),
            Value<bool> isActive = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              OrgsCompanion(
            id: id,
            name: name,
            masterAdminId: masterAdminId,
            isActive: isActive,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String name,
            Value<String?> masterAdminId = const Value.absent(),
            Value<bool> isActive = const Value.absent(),
            required DateTime createdAt,
            Value<DateTime?> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              OrgsCompanion.insert(
            id: id,
            name: name,
            masterAdminId: masterAdminId,
            isActive: isActive,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$OrgsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $OrgsTable,
    OrgsData,
    $$OrgsTableFilterComposer,
    $$OrgsTableOrderingComposer,
    $$OrgsTableAnnotationComposer,
    $$OrgsTableCreateCompanionBuilder,
    $$OrgsTableUpdateCompanionBuilder,
    (OrgsData, BaseReferences<_$AppDatabase, $OrgsTable, OrgsData>),
    OrgsData,
    PrefetchHooks Function()>;
typedef $$CompetitorCategoriesTableCreateCompanionBuilder
    = CompetitorCategoriesCompanion Function({
  required String id,
  required String orgId,
  required String name,
  Value<int> position,
  Value<bool> isActive,
  required DateTime createdAt,
  required DateTime updatedAt,
  Value<int> rowid,
});
typedef $$CompetitorCategoriesTableUpdateCompanionBuilder
    = CompetitorCategoriesCompanion Function({
  Value<String> id,
  Value<String> orgId,
  Value<String> name,
  Value<int> position,
  Value<bool> isActive,
  Value<DateTime> createdAt,
  Value<DateTime> updatedAt,
  Value<int> rowid,
});

class $$CompetitorCategoriesTableFilterComposer
    extends Composer<_$AppDatabase, $CompetitorCategoriesTable> {
  $$CompetitorCategoriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get position => $composableBuilder(
      column: $table.position, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isActive => $composableBuilder(
      column: $table.isActive, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$CompetitorCategoriesTableOrderingComposer
    extends Composer<_$AppDatabase, $CompetitorCategoriesTable> {
  $$CompetitorCategoriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get position => $composableBuilder(
      column: $table.position, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isActive => $composableBuilder(
      column: $table.isActive, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$CompetitorCategoriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $CompetitorCategoriesTable> {
  $$CompetitorCategoriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get orgId =>
      $composableBuilder(column: $table.orgId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<bool> get isActive =>
      $composableBuilder(column: $table.isActive, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$CompetitorCategoriesTableTableManager extends RootTableManager<
    _$AppDatabase,
    $CompetitorCategoriesTable,
    CompetitorCategoryRow,
    $$CompetitorCategoriesTableFilterComposer,
    $$CompetitorCategoriesTableOrderingComposer,
    $$CompetitorCategoriesTableAnnotationComposer,
    $$CompetitorCategoriesTableCreateCompanionBuilder,
    $$CompetitorCategoriesTableUpdateCompanionBuilder,
    (
      CompetitorCategoryRow,
      BaseReferences<_$AppDatabase, $CompetitorCategoriesTable,
          CompetitorCategoryRow>
    ),
    CompetitorCategoryRow,
    PrefetchHooks Function()> {
  $$CompetitorCategoriesTableTableManager(
      _$AppDatabase db, $CompetitorCategoriesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CompetitorCategoriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CompetitorCategoriesTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CompetitorCategoriesTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> orgId = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<int> position = const Value.absent(),
            Value<bool> isActive = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              CompetitorCategoriesCompanion(
            id: id,
            orgId: orgId,
            name: name,
            position: position,
            isActive: isActive,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String orgId,
            required String name,
            Value<int> position = const Value.absent(),
            Value<bool> isActive = const Value.absent(),
            required DateTime createdAt,
            required DateTime updatedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              CompetitorCategoriesCompanion.insert(
            id: id,
            orgId: orgId,
            name: name,
            position: position,
            isActive: isActive,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$CompetitorCategoriesTableProcessedTableManager
    = ProcessedTableManager<
        _$AppDatabase,
        $CompetitorCategoriesTable,
        CompetitorCategoryRow,
        $$CompetitorCategoriesTableFilterComposer,
        $$CompetitorCategoriesTableOrderingComposer,
        $$CompetitorCategoriesTableAnnotationComposer,
        $$CompetitorCategoriesTableCreateCompanionBuilder,
        $$CompetitorCategoriesTableUpdateCompanionBuilder,
        (
          CompetitorCategoryRow,
          BaseReferences<_$AppDatabase, $CompetitorCategoriesTable,
              CompetitorCategoryRow>
        ),
        CompetitorCategoryRow,
        PrefetchHooks Function()>;
typedef $$ProductsTableCreateCompanionBuilder = ProductsCompanion Function({
  required String id,
  required String orgId,
  required String name,
  Value<String?> skuCode,
  Value<int> position,
  Value<bool> isActive,
  required DateTime createdAt,
  required DateTime updatedAt,
  Value<int> rowid,
});
typedef $$ProductsTableUpdateCompanionBuilder = ProductsCompanion Function({
  Value<String> id,
  Value<String> orgId,
  Value<String> name,
  Value<String?> skuCode,
  Value<int> position,
  Value<bool> isActive,
  Value<DateTime> createdAt,
  Value<DateTime> updatedAt,
  Value<int> rowid,
});

class $$ProductsTableFilterComposer
    extends Composer<_$AppDatabase, $ProductsTable> {
  $$ProductsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get skuCode => $composableBuilder(
      column: $table.skuCode, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get position => $composableBuilder(
      column: $table.position, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isActive => $composableBuilder(
      column: $table.isActive, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$ProductsTableOrderingComposer
    extends Composer<_$AppDatabase, $ProductsTable> {
  $$ProductsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get skuCode => $composableBuilder(
      column: $table.skuCode, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get position => $composableBuilder(
      column: $table.position, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isActive => $composableBuilder(
      column: $table.isActive, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$ProductsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ProductsTable> {
  $$ProductsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get orgId =>
      $composableBuilder(column: $table.orgId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get skuCode =>
      $composableBuilder(column: $table.skuCode, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<bool> get isActive =>
      $composableBuilder(column: $table.isActive, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$ProductsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $ProductsTable,
    ProductRow,
    $$ProductsTableFilterComposer,
    $$ProductsTableOrderingComposer,
    $$ProductsTableAnnotationComposer,
    $$ProductsTableCreateCompanionBuilder,
    $$ProductsTableUpdateCompanionBuilder,
    (ProductRow, BaseReferences<_$AppDatabase, $ProductsTable, ProductRow>),
    ProductRow,
    PrefetchHooks Function()> {
  $$ProductsTableTableManager(_$AppDatabase db, $ProductsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ProductsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ProductsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ProductsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> orgId = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<String?> skuCode = const Value.absent(),
            Value<int> position = const Value.absent(),
            Value<bool> isActive = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ProductsCompanion(
            id: id,
            orgId: orgId,
            name: name,
            skuCode: skuCode,
            position: position,
            isActive: isActive,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String orgId,
            required String name,
            Value<String?> skuCode = const Value.absent(),
            Value<int> position = const Value.absent(),
            Value<bool> isActive = const Value.absent(),
            required DateTime createdAt,
            required DateTime updatedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              ProductsCompanion.insert(
            id: id,
            orgId: orgId,
            name: name,
            skuCode: skuCode,
            position: position,
            isActive: isActive,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ProductsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $ProductsTable,
    ProductRow,
    $$ProductsTableFilterComposer,
    $$ProductsTableOrderingComposer,
    $$ProductsTableAnnotationComposer,
    $$ProductsTableCreateCompanionBuilder,
    $$ProductsTableUpdateCompanionBuilder,
    (ProductRow, BaseReferences<_$AppDatabase, $ProductsTable, ProductRow>),
    ProductRow,
    PrefetchHooks Function()>;
typedef $$CompetitorSpottingsTableCreateCompanionBuilder
    = CompetitorSpottingsCompanion Function({
  required String id,
  required String orgId,
  required String customerId,
  required String categoryId,
  required String brandName,
  Value<int?> price,
  Value<String?> specs,
  Value<String?> surveyedByUserId,
  required DateTime surveyedAt,
  required DateTime createdAt,
  Value<String> syncStatus,
  Value<int> rowid,
});
typedef $$CompetitorSpottingsTableUpdateCompanionBuilder
    = CompetitorSpottingsCompanion Function({
  Value<String> id,
  Value<String> orgId,
  Value<String> customerId,
  Value<String> categoryId,
  Value<String> brandName,
  Value<int?> price,
  Value<String?> specs,
  Value<String?> surveyedByUserId,
  Value<DateTime> surveyedAt,
  Value<DateTime> createdAt,
  Value<String> syncStatus,
  Value<int> rowid,
});

class $$CompetitorSpottingsTableFilterComposer
    extends Composer<_$AppDatabase, $CompetitorSpottingsTable> {
  $$CompetitorSpottingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get customerId => $composableBuilder(
      column: $table.customerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get categoryId => $composableBuilder(
      column: $table.categoryId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get brandName => $composableBuilder(
      column: $table.brandName, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get price => $composableBuilder(
      column: $table.price, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get specs => $composableBuilder(
      column: $table.specs, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get surveyedByUserId => $composableBuilder(
      column: $table.surveyedByUserId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get surveyedAt => $composableBuilder(
      column: $table.surveyedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => ColumnFilters(column));
}

class $$CompetitorSpottingsTableOrderingComposer
    extends Composer<_$AppDatabase, $CompetitorSpottingsTable> {
  $$CompetitorSpottingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get customerId => $composableBuilder(
      column: $table.customerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get categoryId => $composableBuilder(
      column: $table.categoryId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get brandName => $composableBuilder(
      column: $table.brandName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get price => $composableBuilder(
      column: $table.price, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get specs => $composableBuilder(
      column: $table.specs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get surveyedByUserId => $composableBuilder(
      column: $table.surveyedByUserId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get surveyedAt => $composableBuilder(
      column: $table.surveyedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => ColumnOrderings(column));
}

class $$CompetitorSpottingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $CompetitorSpottingsTable> {
  $$CompetitorSpottingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get orgId =>
      $composableBuilder(column: $table.orgId, builder: (column) => column);

  GeneratedColumn<String> get customerId => $composableBuilder(
      column: $table.customerId, builder: (column) => column);

  GeneratedColumn<String> get categoryId => $composableBuilder(
      column: $table.categoryId, builder: (column) => column);

  GeneratedColumn<String> get brandName =>
      $composableBuilder(column: $table.brandName, builder: (column) => column);

  GeneratedColumn<int> get price =>
      $composableBuilder(column: $table.price, builder: (column) => column);

  GeneratedColumn<String> get specs =>
      $composableBuilder(column: $table.specs, builder: (column) => column);

  GeneratedColumn<String> get surveyedByUserId => $composableBuilder(
      column: $table.surveyedByUserId, builder: (column) => column);

  GeneratedColumn<DateTime> get surveyedAt => $composableBuilder(
      column: $table.surveyedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => column);
}

class $$CompetitorSpottingsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $CompetitorSpottingsTable,
    CompetitorSpottingRow,
    $$CompetitorSpottingsTableFilterComposer,
    $$CompetitorSpottingsTableOrderingComposer,
    $$CompetitorSpottingsTableAnnotationComposer,
    $$CompetitorSpottingsTableCreateCompanionBuilder,
    $$CompetitorSpottingsTableUpdateCompanionBuilder,
    (
      CompetitorSpottingRow,
      BaseReferences<_$AppDatabase, $CompetitorSpottingsTable,
          CompetitorSpottingRow>
    ),
    CompetitorSpottingRow,
    PrefetchHooks Function()> {
  $$CompetitorSpottingsTableTableManager(
      _$AppDatabase db, $CompetitorSpottingsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CompetitorSpottingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CompetitorSpottingsTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CompetitorSpottingsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> orgId = const Value.absent(),
            Value<String> customerId = const Value.absent(),
            Value<String> categoryId = const Value.absent(),
            Value<String> brandName = const Value.absent(),
            Value<int?> price = const Value.absent(),
            Value<String?> specs = const Value.absent(),
            Value<String?> surveyedByUserId = const Value.absent(),
            Value<DateTime> surveyedAt = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<String> syncStatus = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              CompetitorSpottingsCompanion(
            id: id,
            orgId: orgId,
            customerId: customerId,
            categoryId: categoryId,
            brandName: brandName,
            price: price,
            specs: specs,
            surveyedByUserId: surveyedByUserId,
            surveyedAt: surveyedAt,
            createdAt: createdAt,
            syncStatus: syncStatus,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String orgId,
            required String customerId,
            required String categoryId,
            required String brandName,
            Value<int?> price = const Value.absent(),
            Value<String?> specs = const Value.absent(),
            Value<String?> surveyedByUserId = const Value.absent(),
            required DateTime surveyedAt,
            required DateTime createdAt,
            Value<String> syncStatus = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              CompetitorSpottingsCompanion.insert(
            id: id,
            orgId: orgId,
            customerId: customerId,
            categoryId: categoryId,
            brandName: brandName,
            price: price,
            specs: specs,
            surveyedByUserId: surveyedByUserId,
            surveyedAt: surveyedAt,
            createdAt: createdAt,
            syncStatus: syncStatus,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$CompetitorSpottingsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $CompetitorSpottingsTable,
    CompetitorSpottingRow,
    $$CompetitorSpottingsTableFilterComposer,
    $$CompetitorSpottingsTableOrderingComposer,
    $$CompetitorSpottingsTableAnnotationComposer,
    $$CompetitorSpottingsTableCreateCompanionBuilder,
    $$CompetitorSpottingsTableUpdateCompanionBuilder,
    (
      CompetitorSpottingRow,
      BaseReferences<_$AppDatabase, $CompetitorSpottingsTable,
          CompetitorSpottingRow>
    ),
    CompetitorSpottingRow,
    PrefetchHooks Function()>;
typedef $$PlacementAuditsTableCreateCompanionBuilder = PlacementAuditsCompanion
    Function({
  required String id,
  required String orgId,
  required String customerId,
  required String productId,
  required bool isPresent,
  Value<String?> surveyedByUserId,
  required DateTime surveyedAt,
  required DateTime createdAt,
  Value<String> syncStatus,
  Value<int> rowid,
});
typedef $$PlacementAuditsTableUpdateCompanionBuilder = PlacementAuditsCompanion
    Function({
  Value<String> id,
  Value<String> orgId,
  Value<String> customerId,
  Value<String> productId,
  Value<bool> isPresent,
  Value<String?> surveyedByUserId,
  Value<DateTime> surveyedAt,
  Value<DateTime> createdAt,
  Value<String> syncStatus,
  Value<int> rowid,
});

class $$PlacementAuditsTableFilterComposer
    extends Composer<_$AppDatabase, $PlacementAuditsTable> {
  $$PlacementAuditsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get customerId => $composableBuilder(
      column: $table.customerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get productId => $composableBuilder(
      column: $table.productId, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isPresent => $composableBuilder(
      column: $table.isPresent, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get surveyedByUserId => $composableBuilder(
      column: $table.surveyedByUserId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get surveyedAt => $composableBuilder(
      column: $table.surveyedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => ColumnFilters(column));
}

class $$PlacementAuditsTableOrderingComposer
    extends Composer<_$AppDatabase, $PlacementAuditsTable> {
  $$PlacementAuditsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get customerId => $composableBuilder(
      column: $table.customerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get productId => $composableBuilder(
      column: $table.productId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isPresent => $composableBuilder(
      column: $table.isPresent, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get surveyedByUserId => $composableBuilder(
      column: $table.surveyedByUserId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get surveyedAt => $composableBuilder(
      column: $table.surveyedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => ColumnOrderings(column));
}

class $$PlacementAuditsTableAnnotationComposer
    extends Composer<_$AppDatabase, $PlacementAuditsTable> {
  $$PlacementAuditsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get orgId =>
      $composableBuilder(column: $table.orgId, builder: (column) => column);

  GeneratedColumn<String> get customerId => $composableBuilder(
      column: $table.customerId, builder: (column) => column);

  GeneratedColumn<String> get productId =>
      $composableBuilder(column: $table.productId, builder: (column) => column);

  GeneratedColumn<bool> get isPresent =>
      $composableBuilder(column: $table.isPresent, builder: (column) => column);

  GeneratedColumn<String> get surveyedByUserId => $composableBuilder(
      column: $table.surveyedByUserId, builder: (column) => column);

  GeneratedColumn<DateTime> get surveyedAt => $composableBuilder(
      column: $table.surveyedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => column);
}

class $$PlacementAuditsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $PlacementAuditsTable,
    PlacementAuditRow,
    $$PlacementAuditsTableFilterComposer,
    $$PlacementAuditsTableOrderingComposer,
    $$PlacementAuditsTableAnnotationComposer,
    $$PlacementAuditsTableCreateCompanionBuilder,
    $$PlacementAuditsTableUpdateCompanionBuilder,
    (
      PlacementAuditRow,
      BaseReferences<_$AppDatabase, $PlacementAuditsTable, PlacementAuditRow>
    ),
    PlacementAuditRow,
    PrefetchHooks Function()> {
  $$PlacementAuditsTableTableManager(
      _$AppDatabase db, $PlacementAuditsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlacementAuditsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlacementAuditsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlacementAuditsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> orgId = const Value.absent(),
            Value<String> customerId = const Value.absent(),
            Value<String> productId = const Value.absent(),
            Value<bool> isPresent = const Value.absent(),
            Value<String?> surveyedByUserId = const Value.absent(),
            Value<DateTime> surveyedAt = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<String> syncStatus = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              PlacementAuditsCompanion(
            id: id,
            orgId: orgId,
            customerId: customerId,
            productId: productId,
            isPresent: isPresent,
            surveyedByUserId: surveyedByUserId,
            surveyedAt: surveyedAt,
            createdAt: createdAt,
            syncStatus: syncStatus,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String orgId,
            required String customerId,
            required String productId,
            required bool isPresent,
            Value<String?> surveyedByUserId = const Value.absent(),
            required DateTime surveyedAt,
            required DateTime createdAt,
            Value<String> syncStatus = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              PlacementAuditsCompanion.insert(
            id: id,
            orgId: orgId,
            customerId: customerId,
            productId: productId,
            isPresent: isPresent,
            surveyedByUserId: surveyedByUserId,
            surveyedAt: surveyedAt,
            createdAt: createdAt,
            syncStatus: syncStatus,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$PlacementAuditsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $PlacementAuditsTable,
    PlacementAuditRow,
    $$PlacementAuditsTableFilterComposer,
    $$PlacementAuditsTableOrderingComposer,
    $$PlacementAuditsTableAnnotationComposer,
    $$PlacementAuditsTableCreateCompanionBuilder,
    $$PlacementAuditsTableUpdateCompanionBuilder,
    (
      PlacementAuditRow,
      BaseReferences<_$AppDatabase, $PlacementAuditsTable, PlacementAuditRow>
    ),
    PlacementAuditRow,
    PrefetchHooks Function()>;
typedef $$CatalogProductsTableCreateCompanionBuilder = CatalogProductsCompanion
    Function({
  required String id,
  required String orgId,
  required String name,
  Value<String?> sku,
  Value<double> sellingPrice,
  Value<String?> baseUomId,
  Value<String?> productSubGroup,
  Value<bool> isActive,
  Value<DateTime?> updatedAt,
  Value<String> syncStatus,
  Value<int> rowid,
});
typedef $$CatalogProductsTableUpdateCompanionBuilder = CatalogProductsCompanion
    Function({
  Value<String> id,
  Value<String> orgId,
  Value<String> name,
  Value<String?> sku,
  Value<double> sellingPrice,
  Value<String?> baseUomId,
  Value<String?> productSubGroup,
  Value<bool> isActive,
  Value<DateTime?> updatedAt,
  Value<String> syncStatus,
  Value<int> rowid,
});

class $$CatalogProductsTableFilterComposer
    extends Composer<_$AppDatabase, $CatalogProductsTable> {
  $$CatalogProductsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get sku => $composableBuilder(
      column: $table.sku, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get sellingPrice => $composableBuilder(
      column: $table.sellingPrice, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get baseUomId => $composableBuilder(
      column: $table.baseUomId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get productSubGroup => $composableBuilder(
      column: $table.productSubGroup,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isActive => $composableBuilder(
      column: $table.isActive, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => ColumnFilters(column));
}

class $$CatalogProductsTableOrderingComposer
    extends Composer<_$AppDatabase, $CatalogProductsTable> {
  $$CatalogProductsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get sku => $composableBuilder(
      column: $table.sku, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get sellingPrice => $composableBuilder(
      column: $table.sellingPrice,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get baseUomId => $composableBuilder(
      column: $table.baseUomId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get productSubGroup => $composableBuilder(
      column: $table.productSubGroup,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isActive => $composableBuilder(
      column: $table.isActive, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => ColumnOrderings(column));
}

class $$CatalogProductsTableAnnotationComposer
    extends Composer<_$AppDatabase, $CatalogProductsTable> {
  $$CatalogProductsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get orgId =>
      $composableBuilder(column: $table.orgId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get sku =>
      $composableBuilder(column: $table.sku, builder: (column) => column);

  GeneratedColumn<double> get sellingPrice => $composableBuilder(
      column: $table.sellingPrice, builder: (column) => column);

  GeneratedColumn<String> get baseUomId =>
      $composableBuilder(column: $table.baseUomId, builder: (column) => column);

  GeneratedColumn<String> get productSubGroup => $composableBuilder(
      column: $table.productSubGroup, builder: (column) => column);

  GeneratedColumn<bool> get isActive =>
      $composableBuilder(column: $table.isActive, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => column);
}

class $$CatalogProductsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $CatalogProductsTable,
    CatalogProductRow,
    $$CatalogProductsTableFilterComposer,
    $$CatalogProductsTableOrderingComposer,
    $$CatalogProductsTableAnnotationComposer,
    $$CatalogProductsTableCreateCompanionBuilder,
    $$CatalogProductsTableUpdateCompanionBuilder,
    (
      CatalogProductRow,
      BaseReferences<_$AppDatabase, $CatalogProductsTable, CatalogProductRow>
    ),
    CatalogProductRow,
    PrefetchHooks Function()> {
  $$CatalogProductsTableTableManager(
      _$AppDatabase db, $CatalogProductsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CatalogProductsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CatalogProductsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CatalogProductsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> orgId = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<String?> sku = const Value.absent(),
            Value<double> sellingPrice = const Value.absent(),
            Value<String?> baseUomId = const Value.absent(),
            Value<String?> productSubGroup = const Value.absent(),
            Value<bool> isActive = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
            Value<String> syncStatus = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              CatalogProductsCompanion(
            id: id,
            orgId: orgId,
            name: name,
            sku: sku,
            sellingPrice: sellingPrice,
            baseUomId: baseUomId,
            productSubGroup: productSubGroup,
            isActive: isActive,
            updatedAt: updatedAt,
            syncStatus: syncStatus,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String orgId,
            required String name,
            Value<String?> sku = const Value.absent(),
            Value<double> sellingPrice = const Value.absent(),
            Value<String?> baseUomId = const Value.absent(),
            Value<String?> productSubGroup = const Value.absent(),
            Value<bool> isActive = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
            Value<String> syncStatus = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              CatalogProductsCompanion.insert(
            id: id,
            orgId: orgId,
            name: name,
            sku: sku,
            sellingPrice: sellingPrice,
            baseUomId: baseUomId,
            productSubGroup: productSubGroup,
            isActive: isActive,
            updatedAt: updatedAt,
            syncStatus: syncStatus,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$CatalogProductsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $CatalogProductsTable,
    CatalogProductRow,
    $$CatalogProductsTableFilterComposer,
    $$CatalogProductsTableOrderingComposer,
    $$CatalogProductsTableAnnotationComposer,
    $$CatalogProductsTableCreateCompanionBuilder,
    $$CatalogProductsTableUpdateCompanionBuilder,
    (
      CatalogProductRow,
      BaseReferences<_$AppDatabase, $CatalogProductsTable, CatalogProductRow>
    ),
    CatalogProductRow,
    PrefetchHooks Function()>;
typedef $$FieldOrdersTableCreateCompanionBuilder = FieldOrdersCompanion
    Function({
  required String id,
  required String orgId,
  required String customerId,
  required String salespersonId,
  Value<String> status,
  Value<String?> notes,
  required DateTime createdAt,
  Value<String> syncStatus,
  Value<int> rowid,
});
typedef $$FieldOrdersTableUpdateCompanionBuilder = FieldOrdersCompanion
    Function({
  Value<String> id,
  Value<String> orgId,
  Value<String> customerId,
  Value<String> salespersonId,
  Value<String> status,
  Value<String?> notes,
  Value<DateTime> createdAt,
  Value<String> syncStatus,
  Value<int> rowid,
});

class $$FieldOrdersTableFilterComposer
    extends Composer<_$AppDatabase, $FieldOrdersTable> {
  $$FieldOrdersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get customerId => $composableBuilder(
      column: $table.customerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get salespersonId => $composableBuilder(
      column: $table.salespersonId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get notes => $composableBuilder(
      column: $table.notes, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => ColumnFilters(column));
}

class $$FieldOrdersTableOrderingComposer
    extends Composer<_$AppDatabase, $FieldOrdersTable> {
  $$FieldOrdersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get orgId => $composableBuilder(
      column: $table.orgId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get customerId => $composableBuilder(
      column: $table.customerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get salespersonId => $composableBuilder(
      column: $table.salespersonId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get notes => $composableBuilder(
      column: $table.notes, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => ColumnOrderings(column));
}

class $$FieldOrdersTableAnnotationComposer
    extends Composer<_$AppDatabase, $FieldOrdersTable> {
  $$FieldOrdersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get orgId =>
      $composableBuilder(column: $table.orgId, builder: (column) => column);

  GeneratedColumn<String> get customerId => $composableBuilder(
      column: $table.customerId, builder: (column) => column);

  GeneratedColumn<String> get salespersonId => $composableBuilder(
      column: $table.salespersonId, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => column);
}

class $$FieldOrdersTableTableManager extends RootTableManager<
    _$AppDatabase,
    $FieldOrdersTable,
    FieldOrderRow,
    $$FieldOrdersTableFilterComposer,
    $$FieldOrdersTableOrderingComposer,
    $$FieldOrdersTableAnnotationComposer,
    $$FieldOrdersTableCreateCompanionBuilder,
    $$FieldOrdersTableUpdateCompanionBuilder,
    (
      FieldOrderRow,
      BaseReferences<_$AppDatabase, $FieldOrdersTable, FieldOrderRow>
    ),
    FieldOrderRow,
    PrefetchHooks Function()> {
  $$FieldOrdersTableTableManager(_$AppDatabase db, $FieldOrdersTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FieldOrdersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$FieldOrdersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$FieldOrdersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> orgId = const Value.absent(),
            Value<String> customerId = const Value.absent(),
            Value<String> salespersonId = const Value.absent(),
            Value<String> status = const Value.absent(),
            Value<String?> notes = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<String> syncStatus = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              FieldOrdersCompanion(
            id: id,
            orgId: orgId,
            customerId: customerId,
            salespersonId: salespersonId,
            status: status,
            notes: notes,
            createdAt: createdAt,
            syncStatus: syncStatus,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String orgId,
            required String customerId,
            required String salespersonId,
            Value<String> status = const Value.absent(),
            Value<String?> notes = const Value.absent(),
            required DateTime createdAt,
            Value<String> syncStatus = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              FieldOrdersCompanion.insert(
            id: id,
            orgId: orgId,
            customerId: customerId,
            salespersonId: salespersonId,
            status: status,
            notes: notes,
            createdAt: createdAt,
            syncStatus: syncStatus,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$FieldOrdersTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $FieldOrdersTable,
    FieldOrderRow,
    $$FieldOrdersTableFilterComposer,
    $$FieldOrdersTableOrderingComposer,
    $$FieldOrdersTableAnnotationComposer,
    $$FieldOrdersTableCreateCompanionBuilder,
    $$FieldOrdersTableUpdateCompanionBuilder,
    (
      FieldOrderRow,
      BaseReferences<_$AppDatabase, $FieldOrdersTable, FieldOrderRow>
    ),
    FieldOrderRow,
    PrefetchHooks Function()>;
typedef $$FieldOrderItemsTableCreateCompanionBuilder = FieldOrderItemsCompanion
    Function({
  required String id,
  required String fieldOrderId,
  required String productId,
  Value<String?> uomId,
  Value<double> quantity,
  Value<double> priceAtSubmit,
  Value<String> syncStatus,
  Value<int> rowid,
});
typedef $$FieldOrderItemsTableUpdateCompanionBuilder = FieldOrderItemsCompanion
    Function({
  Value<String> id,
  Value<String> fieldOrderId,
  Value<String> productId,
  Value<String?> uomId,
  Value<double> quantity,
  Value<double> priceAtSubmit,
  Value<String> syncStatus,
  Value<int> rowid,
});

class $$FieldOrderItemsTableFilterComposer
    extends Composer<_$AppDatabase, $FieldOrderItemsTable> {
  $$FieldOrderItemsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get fieldOrderId => $composableBuilder(
      column: $table.fieldOrderId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get productId => $composableBuilder(
      column: $table.productId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get uomId => $composableBuilder(
      column: $table.uomId, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get quantity => $composableBuilder(
      column: $table.quantity, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get priceAtSubmit => $composableBuilder(
      column: $table.priceAtSubmit, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => ColumnFilters(column));
}

class $$FieldOrderItemsTableOrderingComposer
    extends Composer<_$AppDatabase, $FieldOrderItemsTable> {
  $$FieldOrderItemsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get fieldOrderId => $composableBuilder(
      column: $table.fieldOrderId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get productId => $composableBuilder(
      column: $table.productId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get uomId => $composableBuilder(
      column: $table.uomId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get quantity => $composableBuilder(
      column: $table.quantity, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get priceAtSubmit => $composableBuilder(
      column: $table.priceAtSubmit,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => ColumnOrderings(column));
}

class $$FieldOrderItemsTableAnnotationComposer
    extends Composer<_$AppDatabase, $FieldOrderItemsTable> {
  $$FieldOrderItemsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get fieldOrderId => $composableBuilder(
      column: $table.fieldOrderId, builder: (column) => column);

  GeneratedColumn<String> get productId =>
      $composableBuilder(column: $table.productId, builder: (column) => column);

  GeneratedColumn<String> get uomId =>
      $composableBuilder(column: $table.uomId, builder: (column) => column);

  GeneratedColumn<double> get quantity =>
      $composableBuilder(column: $table.quantity, builder: (column) => column);

  GeneratedColumn<double> get priceAtSubmit => $composableBuilder(
      column: $table.priceAtSubmit, builder: (column) => column);

  GeneratedColumn<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => column);
}

class $$FieldOrderItemsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $FieldOrderItemsTable,
    FieldOrderItemRow,
    $$FieldOrderItemsTableFilterComposer,
    $$FieldOrderItemsTableOrderingComposer,
    $$FieldOrderItemsTableAnnotationComposer,
    $$FieldOrderItemsTableCreateCompanionBuilder,
    $$FieldOrderItemsTableUpdateCompanionBuilder,
    (
      FieldOrderItemRow,
      BaseReferences<_$AppDatabase, $FieldOrderItemsTable, FieldOrderItemRow>
    ),
    FieldOrderItemRow,
    PrefetchHooks Function()> {
  $$FieldOrderItemsTableTableManager(
      _$AppDatabase db, $FieldOrderItemsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FieldOrderItemsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$FieldOrderItemsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$FieldOrderItemsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> fieldOrderId = const Value.absent(),
            Value<String> productId = const Value.absent(),
            Value<String?> uomId = const Value.absent(),
            Value<double> quantity = const Value.absent(),
            Value<double> priceAtSubmit = const Value.absent(),
            Value<String> syncStatus = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              FieldOrderItemsCompanion(
            id: id,
            fieldOrderId: fieldOrderId,
            productId: productId,
            uomId: uomId,
            quantity: quantity,
            priceAtSubmit: priceAtSubmit,
            syncStatus: syncStatus,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String fieldOrderId,
            required String productId,
            Value<String?> uomId = const Value.absent(),
            Value<double> quantity = const Value.absent(),
            Value<double> priceAtSubmit = const Value.absent(),
            Value<String> syncStatus = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              FieldOrderItemsCompanion.insert(
            id: id,
            fieldOrderId: fieldOrderId,
            productId: productId,
            uomId: uomId,
            quantity: quantity,
            priceAtSubmit: priceAtSubmit,
            syncStatus: syncStatus,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$FieldOrderItemsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $FieldOrderItemsTable,
    FieldOrderItemRow,
    $$FieldOrderItemsTableFilterComposer,
    $$FieldOrderItemsTableOrderingComposer,
    $$FieldOrderItemsTableAnnotationComposer,
    $$FieldOrderItemsTableCreateCompanionBuilder,
    $$FieldOrderItemsTableUpdateCompanionBuilder,
    (
      FieldOrderItemRow,
      BaseReferences<_$AppDatabase, $FieldOrderItemsTable, FieldOrderItemRow>
    ),
    FieldOrderItemRow,
    PrefetchHooks Function()>;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$CustomersTableTableManager get customers =>
      $$CustomersTableTableManager(_db, _db.customers);
  $$SalesRoutesTableTableTableManager get salesRoutesTable =>
      $$SalesRoutesTableTableTableManager(_db, _db.salesRoutesTable);
  $$RouteStopsTableTableManager get routeStops =>
      $$RouteStopsTableTableManager(_db, _db.routeStops);
  $$TripsTableTableManager get trips =>
      $$TripsTableTableManager(_db, _db.trips);
  $$TripStopsTableTableManager get tripStops =>
      $$TripStopsTableTableManager(_db, _db.tripStops);
  $$VisitsTableTableManager get visits =>
      $$VisitsTableTableManager(_db, _db.visits);
  $$AppConfigTableTableManager get appConfig =>
      $$AppConfigTableTableManager(_db, _db.appConfig);
  $$AuditLogsTableTableManager get auditLogs =>
      $$AuditLogsTableTableManager(_db, _db.auditLogs);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db, _db.users);
  $$RouteAssignmentsTableTableManager get routeAssignments =>
      $$RouteAssignmentsTableTableManager(_db, _db.routeAssignments);
  $$UploadQueueTableTableManager get uploadQueue =>
      $$UploadQueueTableTableManager(_db, _db.uploadQueue);
  $$DeliveriesTableTableManager get deliveries =>
      $$DeliveriesTableTableManager(_db, _db.deliveries);
  $$DeliveryStopsTableTableManager get deliveryStops =>
      $$DeliveryStopsTableTableManager(_db, _db.deliveryStops);
  $$OrgsTableTableManager get orgs => $$OrgsTableTableManager(_db, _db.orgs);
  $$CompetitorCategoriesTableTableManager get competitorCategories =>
      $$CompetitorCategoriesTableTableManager(_db, _db.competitorCategories);
  $$ProductsTableTableManager get products =>
      $$ProductsTableTableManager(_db, _db.products);
  $$CompetitorSpottingsTableTableManager get competitorSpottings =>
      $$CompetitorSpottingsTableTableManager(_db, _db.competitorSpottings);
  $$PlacementAuditsTableTableManager get placementAudits =>
      $$PlacementAuditsTableTableManager(_db, _db.placementAudits);
  $$CatalogProductsTableTableManager get catalogProducts =>
      $$CatalogProductsTableTableManager(_db, _db.catalogProducts);
  $$FieldOrdersTableTableManager get fieldOrders =>
      $$FieldOrdersTableTableManager(_db, _db.fieldOrders);
  $$FieldOrderItemsTableTableManager get fieldOrderItems =>
      $$FieldOrderItemsTableTableManager(_db, _db.fieldOrderItems);
}
