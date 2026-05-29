/// A subtitle rendition advertised by an HLS manifest.
///
/// Platform-agnostic value type so callers don't depend on the hls.js interop.
class HlsSubtitleTrack {
  const HlsSubtitleTrack({
    required this.id,
    this.label,
    this.language,
    this.isDefault = false,
  });

  /// Index used to select this track (see `setSubtitleTrack`). `-1` disables.
  final int id;

  /// Human-readable name from the manifest (`NAME`).
  final String? label;

  /// BCP-47 language tag from the manifest (`LANGUAGE`), when present.
  final String? language;

  /// Whether the manifest marked this rendition as the default.
  final bool isDefault;

  @override
  bool operator ==(Object other) =>
      other is HlsSubtitleTrack &&
      other.id == id &&
      other.label == label &&
      other.language == language &&
      other.isDefault == isDefault;

  @override
  int get hashCode => Object.hash(id, label, language, isDefault);

  @override
  String toString() =>
      'HlsSubtitleTrack(id: $id, label: $label, language: $language, '
      'isDefault: $isDefault)';
}
