import '../utils/text_cleaner.dart';

class Artist {
  final String id;
  final String name;
  final String? imageUrl;
  final String? role;
  final bool isVerified;
  final int? followerCount;

  Artist({
    required this.id,
    required this.name,
    this.imageUrl,
    this.role,
    this.isVerified = false,
    this.followerCount,
  });

  factory Artist.fromJson(Map<String, dynamic> json) {
    String? imageUrl;
    if (json['image'] is List && (json['image'] as List).isNotEmpty) {
      imageUrl =
          (json['image'] as List).last['url'] ??
          (json['image'] as List).last['link'];
    } else if (json['image'] is String) {
      imageUrl = json['image'];
    }

    return Artist(
      id: json['id']?.toString() ?? '',
      name: TextCleaner.decodeHtmlEntities(
        (json['name'] ?? json['title'] ?? 'Unknown').toString(),
      ),
      imageUrl: imageUrl,
      role: TextCleaner.decodeHtmlEntities(
        (json['role'] ?? json['type'] ?? '').toString(),
      ),
      isVerified: json['isVerified'] == true || json['verified'] == true,
      followerCount: int.tryParse(
        (json['followerCount'] ??
                json['follower_count'] ??
                json['followers'] ??
                '')
            .toString(),
      ),
    );
  }
}
