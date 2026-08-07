// lib/models/profile.dart
enum ProfileType { singBox, netbird }

class Profile {
  final String id;
  ProfileType type;
  String name;
  String config;      // sing-box JSON content (only for singBox type)
  bool active;
  final DateTime createdAt;
  DateTime updatedAt;

  // Netbird config fields (only for netbird type)
  String? netbirdSetupKey;
  String? netbirdJWTToken;
  String? netbirdManagementUrl;
  String? netbirdDeviceName;

  bool get hasNetbirdConfig =>
      (netbirdSetupKey != null && netbirdSetupKey!.isNotEmpty) ||
      (netbirdJWTToken != null && netbirdJWTToken!.isNotEmpty);

  /// Display label suffix for the config area
  String get typeLabel => type == ProfileType.singBox ? 'sing-box' : 'Netbird';

  Profile({
    required this.id,
    required this.type,
    required this.name,
    this.config = '',
    this.active = false,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.netbirdSetupKey,
    this.netbirdJWTToken,
    this.netbirdManagementUrl,
    this.netbirdDeviceName,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type == ProfileType.singBox ? 'sing-box' : 'netbird',
        'name': name,
        'config': config,
        'active': active,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        if (type == ProfileType.netbird) ...{
          if (netbirdSetupKey != null && netbirdSetupKey!.isNotEmpty)
            'netbird_setup_key': netbirdSetupKey,
          if (netbirdJWTToken != null && netbirdJWTToken!.isNotEmpty)
            'netbird_jwt_token': netbirdJWTToken,
          if (netbirdManagementUrl != null && netbirdManagementUrl!.isNotEmpty)
            'netbird_management_url': netbirdManagementUrl,
          if (netbirdDeviceName != null && netbirdDeviceName!.isNotEmpty)
            'netbird_device_name': netbirdDeviceName,
        },
      };

  factory Profile.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? 'sing-box';
    final type = typeStr == 'netbird' ? ProfileType.netbird : ProfileType.singBox;
    return Profile(
      id: json['id'] ?? '',
      type: type,
      name: json['name'] ?? '',
      config: json['config'] ?? '',
      active: json['active'] ?? false,
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(json['updated_at'] ?? '') ?? DateTime.now(),
      netbirdSetupKey: json['netbird_setup_key'] as String?,
      netbirdJWTToken: json['netbird_jwt_token'] as String?,
      netbirdManagementUrl: json['netbird_management_url'] as String?,
      netbirdDeviceName: json['netbird_device_name'] as String?,
    );
  }

  Profile copyWith({
    ProfileType? type,
    String? name,
    String? config,
    bool? active,
    String? netbirdSetupKey,
    String? netbirdJWTToken,
    String? netbirdManagementUrl,
    String? netbirdDeviceName,
  }) =>
      Profile(
        id: id,
        type: type ?? this.type,
        name: name ?? this.name,
        config: config ?? this.config,
        active: active ?? this.active,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
        netbirdSetupKey: netbirdSetupKey ?? this.netbirdSetupKey,
        netbirdJWTToken: netbirdJWTToken ?? this.netbirdJWTToken,
        netbirdManagementUrl: netbirdManagementUrl ?? this.netbirdManagementUrl,
        netbirdDeviceName: netbirdDeviceName ?? this.netbirdDeviceName,
      );
}
