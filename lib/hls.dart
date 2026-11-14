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
  external void destroy();

  external void loadSource(String videoSrc);

  external void attachMedia(web.HTMLVideoElement video);

  external void on(String event, JSFunction callback);

  external HlsConfig config;

  external JSArray<HlsAudioTrackJs> get audioTracks;

  external int audioTrack;
}

extension type HlsAudioTrackJs._(JSObject _) implements JSObject {
  external String? get name;
  external String? get lang;
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

extension type ErrorData._(JSObject _) implements JSObject {
  external String get type;
  external String get details;
  external bool get fatal;
}
