class StreamMetadata {
  final String streamUrl;
  final int? bitrate;
  final DateTime? expiry;
  final String? provider;

  const StreamMetadata({
    required this.streamUrl,
    this.bitrate,
    this.expiry,
    this.provider,
  });
}
