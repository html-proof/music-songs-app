class LanguageUtils {
  static const Map<String, String> _aliases = <String, String>{
    'hi': 'hindi',
    'hin': 'hindi',
    'en': 'english',
    'eng': 'english',
    'ml': 'malayalam',
    'mal': 'malayalam',
    'ta': 'tamil',
    'tam': 'tamil',
    'te': 'telugu',
    'tel': 'telugu',
    'ka': 'kannada',
    'kan': 'kannada',
    'bn': 'bengali',
    'ben': 'bengali',
    'pa': 'punjabi',
    'pun': 'punjabi',
    'mr': 'marathi',
    'mar': 'marathi',
    'gu': 'gujarati',
    'guj': 'gujarati',
    'bh': 'bhojpuri',
    'bho': 'bhojpuri',
    'ur': 'urdu',
    'urd': 'urdu',
  };

  static List<String> normalizeLanguageList(Iterable<String> languages) {
    final output = <String>{};
    for (final language in languages) {
      final normalized = normalizeLanguage(language);
      if (normalized.isNotEmpty) {
        output.add(normalized);
      }
    }
    return output.toList(growable: false);
  }

  static Set<String> normalizeLanguageSet(Iterable<String> languages) {
    return normalizeLanguageList(languages).toSet();
  }

  static String normalizeLanguage(String language) {
    final base = language
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (base.isEmpty) return '';
    return _aliases[base] ?? base;
  }

  static Set<String> extractLanguageTokens(dynamic rawLanguage) {
    final tokens = <String>{};

    void read(dynamic value) {
      if (value == null) return;

      if (value is Iterable) {
        for (final item in value) {
          read(item);
        }
        return;
      }

      final text = value.toString().trim();
      if (text.isEmpty) return;
      final parts = text.split(RegExp(r'[,/|;&+]'));
      for (final part in parts) {
        final normalized = normalizeLanguage(part);
        if (normalized.isNotEmpty) {
          tokens.add(normalized);
          if (normalized.contains(' ')) {
            for (final fragment in normalized.split(' ')) {
              final fragmentNormalized = normalizeLanguage(fragment);
              if (fragmentNormalized.isNotEmpty) {
                tokens.add(fragmentNormalized);
              }
            }
          }
        }
      }
    }

    read(rawLanguage);
    return tokens;
  }

  static bool matchesPreferredLanguages(
    dynamic rawLanguage,
    Set<String> preferredLanguages,
  ) {
    if (preferredLanguages.isEmpty) return true;
    final tokens = extractLanguageTokens(rawLanguage);
    if (tokens.isEmpty) return false;
    return tokens.any(preferredLanguages.contains);
  }

  static String displayLabel(String language) {
    final normalized = normalizeLanguage(language);
    if (normalized.isEmpty) return '';
    return normalized
        .split(' ')
        .where((part) => part.isNotEmpty)
        .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
        .join(' ');
  }
}
