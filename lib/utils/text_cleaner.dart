class TextCleaner {
  static String decodeHtmlEntities(String value) {
    if (value.isEmpty) return value;

    var decoded = value;

    // Handle malformed entities like "& quot ;", "& amp ;", etc.
    decoded = decoded.replaceAll(
      RegExp(r'&\s*quot\s*;?', caseSensitive: false),
      '"',
    );
    decoded = decoded.replaceAll(
      RegExp(r'&\s*apos\s*;?', caseSensitive: false),
      "'",
    );
    decoded = decoded.replaceAll(
      RegExp(r'&\s*amp\s*;?', caseSensitive: false),
      '&',
    );
    decoded = decoded.replaceAll(
      RegExp(r'&\s*lt\s*;?', caseSensitive: false),
      '<',
    );
    decoded = decoded.replaceAll(
      RegExp(r'&\s*gt\s*;?', caseSensitive: false),
      '>',
    );
    decoded = decoded.replaceAll(
      RegExp(r'&\s*nbsp\s*;?', caseSensitive: false),
      ' ',
    );

    const namedEntities = {
      '&quot;': '"',
      '&apos;': "'",
      '&#039;': "'",
      '&amp;': '&',
      '&lt;': '<',
      '&gt;': '>',
      '&nbsp;': ' ',
    };

    namedEntities.forEach((entity, replacement) {
      decoded = decoded.replaceAll(entity, replacement);
    });

    // Decode numeric entities like &#34; and &#x22;
    decoded = decoded.replaceAllMapped(RegExp(r'&#(\d+);'), (match) {
      final code = int.tryParse(match.group(1) ?? '');
      if (code == null) return match.group(0) ?? '';
      return String.fromCharCode(code);
    });

    decoded = decoded.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (match) {
      final code = int.tryParse(match.group(1) ?? '', radix: 16);
      if (code == null) return match.group(0) ?? '';
      return String.fromCharCode(code);
    });

    return decoded.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
