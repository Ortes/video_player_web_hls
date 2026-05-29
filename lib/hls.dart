@JS()
library hls.js;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

@JS('Hls.isSupported')
external bool isSupported();

@JS()
@staticInterop
class Hls {
  external factory Hls(HlsConfig config);
}

extension HlsExtension on Hls {
  external void stopLoad();

  external void loadSource(String videoSrc);

  external void attachMedia(web.HTMLVideoElement video);

  external void on(String event, JSFunction callback);

  external void off(String event, JSFunction callback);

  external HlsConfig config;

  /// The alternate subtitle renditions declared in the manifest.
  external JSArray<HlsSubtitleTrackJs> get subtitleTracks;

  /// Index into [subtitleTracks] of the active subtitle rendition, or `-1`
  /// when subtitles are disabled. Assigning switches the rendition.
  external int subtitleTrack;

  /// Whether hls.js renders subtitle cues natively onto the `<video>` element.
  ///
  /// When `false`, hls.js still parses the cues into a `hidden` [web.TextTrack]
  /// (so `cuechange` fires and `activeCues` is populated) but draws nothing,
  /// letting the host (e.g. Flutter) render them instead.
  external bool subtitleDisplay;

  /// The alternate audio renditions declared in the manifest.
  external JSArray<HlsAudioTrackJs> get audioTracks;

  /// Index into [audioTracks] of the active audio rendition. Assigning
  /// switches the rendition (there is always an active audio track).
  external int audioTrack;
}

/// hls.js subtitle-track descriptor as exposed on [HlsExtension.subtitleTracks].
extension type HlsSubtitleTrackJs._(JSObject _) implements JSObject {
  external int get id;
  external String? get name;
  external String? get lang;

  @JS('default')
  external bool get isDefault;
}

/// hls.js audio-track descriptor as exposed on [HlsExtension.audioTracks].
extension type HlsAudioTrackJs._(JSObject _) implements JSObject {
  external int get id;
  external String? get name;
  external String? get lang;

  @JS('default')
  external bool get isDefault;
}

@JS()
@anonymous
@staticInterop
class HlsConfig {
  external factory HlsConfig({JSFunction xhrSetup, JSBoolean debug});
}

extension HlsConfigExtension on HlsConfig {
  external JSFunction get xhrSetup;
}

class ErrorData {
  late final String type;
  late final String details;
  late final bool fatal;

  ErrorData(dynamic errorData) {
    type = errorData.type as String;
    details = errorData.details as String;
    fatal = errorData.fatal as bool;
  }
}
