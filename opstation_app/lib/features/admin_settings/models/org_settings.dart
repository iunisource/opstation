class OrgSettings {
  final String cutoffTime;
  final int geofenceRadiusMeters;
  final int accuracyWarnMeters;
  final int scoreBadMax;
  final int scoreOkMax;
  final List<String> categories;
  final List<String> groups;
  final String osrmBaseUrl;
  final String nominatimBaseUrl;
  final int complianceLookbackTrips;
  final int complianceThresholdOccurrences;
  final String smsApiUrl;
  final String smsApiMethod;
  final String smsApiHeaders;
  final String smsApiBody;
  final String smsApiKey;
  final String smsSenderId;
  final String smsVisitTemplate;
  final String smsDeliveryTemplate;
  final bool smsEnabled;

  const OrgSettings({
    required this.cutoffTime,
    required this.geofenceRadiusMeters,
    required this.accuracyWarnMeters,
    required this.scoreBadMax,
    required this.scoreOkMax,
    required this.categories,
    required this.groups,
    required this.osrmBaseUrl,
    required this.nominatimBaseUrl,
    required this.complianceLookbackTrips,
    required this.complianceThresholdOccurrences,
    this.smsApiUrl = '',
    this.smsApiMethod = 'GET',
    this.smsApiHeaders = '{}',
    this.smsApiBody = '',
    this.smsApiKey = '',
    this.smsSenderId = '',
    this.smsVisitTemplate = 'Dear {customer_name}, payment of Rs. {amount} received. Receipt: {receipt_no}. Thank you.',
    this.smsDeliveryTemplate = 'Dear {customer_name}, your delivery of Rs. {amount} has been completed. Thank you.',
    this.smsEnabled = false,
  });

  static const defaults = OrgSettings(
    cutoffTime: '23:00',
    geofenceRadiusMeters: 100,
    accuracyWarnMeters: 50,
    scoreBadMax: 40,
    scoreOkMax: 70,
    categories: [
      'Retailer', 'Wholesaler', 'Distributor', 'Projects',
      'Corporate', 'Government', 'HORECA',
    ],
    groups: [
      'PAKLITE Commercial', 'Projects', 'Retail', 'Wholesale', 'Export',
    ],
    osrmBaseUrl: 'https://router.project-osrm.org',
    nominatimBaseUrl: 'https://nominatim.openstreetmap.org',
    complianceLookbackTrips: 10,
    complianceThresholdOccurrences: 2,
  );

  OrgSettings copyWith({
    String? cutoffTime,
    int? geofenceRadiusMeters,
    int? accuracyWarnMeters,
    int? scoreBadMax,
    int? scoreOkMax,
    List<String>? categories,
    List<String>? groups,
    String? osrmBaseUrl,
    String? nominatimBaseUrl,
    int? complianceLookbackTrips,
    int? complianceThresholdOccurrences,
    String? smsApiUrl,
    String? smsApiMethod,
    String? smsApiHeaders,
    String? smsApiBody,
    String? smsApiKey,
    String? smsSenderId,
    String? smsVisitTemplate,
    String? smsDeliveryTemplate,
    bool? smsEnabled,
  }) {
    return OrgSettings(
      cutoffTime: cutoffTime ?? this.cutoffTime,
      geofenceRadiusMeters: geofenceRadiusMeters ?? this.geofenceRadiusMeters,
      accuracyWarnMeters: accuracyWarnMeters ?? this.accuracyWarnMeters,
      scoreBadMax: scoreBadMax ?? this.scoreBadMax,
      scoreOkMax: scoreOkMax ?? this.scoreOkMax,
      categories: categories ?? this.categories,
      groups: groups ?? this.groups,
      osrmBaseUrl: osrmBaseUrl ?? this.osrmBaseUrl,
      nominatimBaseUrl: nominatimBaseUrl ?? this.nominatimBaseUrl,
      complianceLookbackTrips: complianceLookbackTrips ?? this.complianceLookbackTrips,
      complianceThresholdOccurrences: complianceThresholdOccurrences ?? this.complianceThresholdOccurrences,
      smsApiUrl: smsApiUrl ?? this.smsApiUrl,
      smsApiMethod: smsApiMethod ?? this.smsApiMethod,
      smsApiHeaders: smsApiHeaders ?? this.smsApiHeaders,
      smsApiBody: smsApiBody ?? this.smsApiBody,
      smsApiKey: smsApiKey ?? this.smsApiKey,
      smsSenderId: smsSenderId ?? this.smsSenderId,
      smsVisitTemplate: smsVisitTemplate ?? this.smsVisitTemplate,
      smsDeliveryTemplate: smsDeliveryTemplate ?? this.smsDeliveryTemplate,
      smsEnabled: smsEnabled ?? this.smsEnabled,
    );
  }
}
