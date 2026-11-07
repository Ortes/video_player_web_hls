// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:video_player_web_hls/hls.dart';
import 'package:video_player_web_hls/no_script_tag_exception.dart';
import 'package:video_player_web_hls/src/pkg_web_tweaks.dart';
import 'package:video_player_web_hls/src/subtitle_track.dart';
import 'package:web/web.dart' as web;

import 'duration_utils.dart';

// hls.js event names used for subtitle handling.
const String _kHlsSubtitleTracksUpdated = 'hlsSubtitleTracksUpdated';
const String _kHlsSubtitleTrackSwitch = 'hlsSubtitleTrackSwitch';

// An error code value to error name Map.
// See: https://developer.mozilla.org/en-US/docs/Web/API/MediaError/code
const Map<int, String> _kErrorValueToErrorName = <int, String>{
  1: 'MEDIA_ERR_ABORTED',
  2: 'MEDIA_ERR_NETWORK',
  3: 'MEDIA_ERR_DECODE',
  4: 'MEDIA_ERR_SRC_NOT_SUPPORTED',
};

// An error code value to description Map.
// See: https://developer.mozilla.org/en-US/docs/Web/API/MediaError/code
const Map<int, String> _kErrorValueToErrorDescription = <int, String>{
  1: 'The user canceled the fetching of the video.',
  2: 'A network error occurred while fetching the video, despite having previously been available.',
  3: 'An error occurred while trying to decode the video, despite having previously been determined to be usable.',
  4: 'The video has been found to be unsuitable (missing or in a format not supported by your browser).',
  5: 'Could not load manifest'
};

// The default error message, when the error is an empty string
// See: https://developer.mozilla.org/en-US/docs/Web/API/MediaError/message
const String _kDefaultErrorMessage = 'No further diagnostic information can be determined or provided.';

/// Wraps a [html.VideoElement] so its API complies with what is expected by the plugin.
class VideoPlayer {
  /// Create a [VideoPlayer] from a [html.VideoElement] instance.
  VideoPlayer({
    required web.HTMLVideoElement videoElement,
    required this.uri,
    required this.headers,
    @visibleForTesting StreamController<VideoEvent>? eventController,
  })  : _videoElement = videoElement,
        _eventController = eventController ?? StreamController<VideoEvent>();

  final StreamController<VideoEvent> _eventController;
  final web.HTMLVideoElement _videoElement;
  web.EventHandler? _onContextMenu;

  final String uri;
  final Map<String, String> headers;

  bool _isInitialized = false;
  bool _isBuffering = false;
  Hls? _hls;

  /// Force use hlsjs when set to `true`.
  bool? _hlsFallback;

  // ---- In-place source swap (audio-track switching) ---------------------
  // The source hls.js should (re)load. Starts as [uri]; [switchSource] updates
  // it so that when hls.js re-fires MEDIA_ATTACHED on loadSource (it resets the
  // MediaSource), the re-attach handler reloads the SWITCHED source rather than
  // the original — otherwise the switch is immediately clobbered.
  late String _currentSource = uri;
  // True while a [switchSource] is in flight: guards the `ended` handler from
  // emitting a spurious `completed` when hls.js tears down the MediaSource.
  bool _isSwitching = false;
  // Incremented per switch so stale one-shot handlers from an earlier (rapid)
  // switch no-op instead of seeking/playing the wrong source.
  int _switchGen = 0;

  /// Returns the [Stream] of [VideoEvent]s from the inner [html.VideoElement].
  Stream<VideoEvent> get events => _eventController.stream;

  final List<StreamSubscription> _eventsSubscriptions = [];

  // ---- Subtitle tracks --------------------------------------------------

  final StreamController<String?> _subtitleCueController =
      StreamController<String?>.broadcast();
  final StreamController<void> _subtitleTracksController =
      StreamController<void>.broadcast();

  // When hls.js doesn't render cues itself ([_subtitleDisplay] is false), the
  // selected rendition's native TextTrack is set to `hidden`: cues are parsed
  // and `cuechange` fires, but nothing is painted. We listen on that track and
  // forward the active cue text so the host can render it.
  web.TextTrack? _activeCueTrack;
  bool _subtitleDisplay = false;
  JSFunction? _onHlsSubtitleTracksUpdated;
  JSFunction? _onHlsSubtitleTrackSwitch;
  late final web.EventListener _cueChangeListener =
      ((web.Event _) => _emitActiveCues()).toJS;

  /// Subtitle renditions advertised by the manifest. Empty when not playing
  /// through hls.js or before the manifest is parsed.
  List<HlsSubtitleTrack> get subtitleTracks {
    final hls = _hls;
    if (hls == null) return const <HlsSubtitleTrack>[];
    return hls.subtitleTracks.toDart
        .map((t) => HlsSubtitleTrack(
              id: t.id,
              label: t.name,
              language: t.lang,
              isDefault: t.isDefault,
            ))
        .toList(growable: false);
  }

  /// Index of the active subtitle rendition, or `-1` when subtitles are off.
  int get subtitleTrack => _hls?.subtitleTrack ?? -1;

  set subtitleTrack(int id) {
    final hls = _hls;
    if (hls == null) return;
    hls.subtitleTrack = id;
    // `hlsSubtitleTrackSwitch` re-wires the cue listener; do it eagerly too so
    // disabling (id < 0) clears any showing cue immediately.
    _rewireActiveCueTrack();
  }

  /// Whether hls.js paints subtitle cues itself. Defaults to `false` so the
  /// host renders them; flip to `true` to hand rendering back to the browser.
  bool get subtitleDisplay => _subtitleDisplay;

  set subtitleDisplay(bool value) {
    _subtitleDisplay = value;
    _hls?.subtitleDisplay = value;
    _rewireActiveCueTrack();
  }

  /// The active subtitle cue text (newline-joined), or `null` when none is
  /// showing. Only emits while [subtitleDisplay] is `false`.
  Stream<String?> get subtitleCues => _subtitleCueController.stream;

  /// Fires whenever the set of [subtitleTracks] or the active selection
  /// changes, so callers can refresh their UI.
  Stream<void> get subtitleTracksChanged => _subtitleTracksController.stream;

  void _emitActiveCues() {
    final track = _activeCueTrack;
    final cues = track?.activeCues;
    if (track == null || cues == null || cues.length == 0) {
      _subtitleCueController.add(null);
      return;
    }
    final parts = <String>[];
    for (var i = 0; i < cues.length; i++) {
      final cue = cues.getProperty<web.TextTrackCue>(i.toJS);
      // All HLS WebVTT cues are VTTCues, which expose the rendered text.
      if (cue.isA<web.VTTCue>()) parts.add((cue as web.VTTCue).text);
    }
    _subtitleCueController.add(parts.isEmpty ? null : parts.join('\n'));
  }

  void _rewireActiveCueTrack() {
    _activeCueTrack?.removeEventListener('cuechange', _cueChangeListener);
    _activeCueTrack = null;

    if (_subtitleDisplay || (_hls?.subtitleTrack ?? -1) < 0) {
      _subtitleCueController.add(null);
      return;
    }

    final tracks = _videoElement.textTracks;
    for (var i = 0; i < tracks.length; i++) {
      final track = tracks.getProperty<web.TextTrack>(i.toJS);
      if (track.mode != 'disabled') {
        _activeCueTrack = track;
        break;
      }
    }
    _activeCueTrack?.addEventListener('cuechange', _cueChangeListener);
    _emitActiveCues();
  }

  // ---- In-place source swap --------------------------------------------

  /// Swaps the playing HLS source to [url] in place (without recreating the
  /// `<video>` element / platform texture), restoring playback to
  /// [startPositionSeconds] and preserving the active subtitle selection.
  ///
  /// Used for audio-track switching under a muxed HLS model, where each audio
  /// track is a distinct fMP4 variant rather than an hls.js audio rendition:
  /// the caller passes a new master URL whose variant embeds the chosen track.
  /// A brief rebuffer is expected.
  ///
  /// No-op on the native (non-hls.js) path — there the caller should recreate
  /// the player instead.
  void switchSource(String url, double startPositionSeconds) {
    final hls = _hls;
    if (hls == null) return;

    final wasPlaying = !_videoElement.paused;
    final previousSubtitleId = hls.subtitleTrack;
    _isSwitching = true;
    final gen = ++_switchGen;

    // Tell hls.js where to resume; this avoids seeking before `seekable` is
    // populated (MANIFEST_PARSED is too early and would clamp to 0).
    hls.config.startPosition = startPositionSeconds;

    late final JSFunction onManifestParsed;
    onManifestParsed = ((String _, JSObject __) {
      if (gen != _switchGen) {
        hls.off('hlsManifestParsed', onManifestParsed);
        return;
      }
      _isSwitching = false;
      hls.off('hlsManifestParsed', onManifestParsed);
    }).toJS;

    late final JSFunction onSubsUpdated;
    onSubsUpdated = ((String _, JSObject __) {
      if (gen != _switchGen) {
        hls.off(_kHlsSubtitleTracksUpdated, onSubsUpdated);
        return;
      }
      // hls.js resets the active subtitle to -1 on reload; re-apply the prior
      // selection so the chosen language survives the swap.
      if (previousSubtitleId >= 0) {
        hls.subtitleTrack = previousSubtitleId;
        _rewireActiveCueTrack();
      }
      hls.off(_kHlsSubtitleTracksUpdated, onSubsUpdated);
    }).toJS;

    late final JSFunction onFragBuffered;
    onFragBuffered = ((String _, JSObject __) {
      if (gen != _switchGen) {
        hls.off('hlsFragBuffered', onFragBuffered);
        return;
      }
      if (wasPlaying) play();
      hls.off('hlsFragBuffered', onFragBuffered);
    }).toJS;

    hls.on('hlsManifestParsed', onManifestParsed);
    hls.on(_kHlsSubtitleTracksUpdated, onSubsUpdated);
    hls.on('hlsFragBuffered', onFragBuffered);

    _currentSource = url; // a media re-attach must reload the new source
    hls.stopLoad(); // drain in-flight requests before swapping
    hls.loadSource(url);
  }

  /// Initializes the wrapped [html.VideoElement].
  ///
  /// This method sets the required DOM attributes so videos can [play] programmatically,
  /// and attaches listeners to the internal events from the [html.VideoElement]
  /// to react to them / expose them through the [VideoPlayer.events] stream.
  /// Cineseed verbose HLS logging, toggled at runtime by the host app setting
  /// `window.__cineseedHlsVerbose = true` (driven by the server's CINESEED_DEBUG
  /// / `?debug=1`). Read defensively — absent/non-boolean → off.
  bool get _hlsVerbose {
    try {
      return globalContext
              .getProperty<JSBoolean?>('__cineseedHlsVerbose'.toJS)
              ?.toDart ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Best-effort fragment sequence number from an hls.js frag event payload.
  int? _fragSn(JSObject data) {
    try {
      final frag = data.getProperty<JSObject?>('frag'.toJS);
      final sn = frag?.getProperty<JSAny?>('sn'.toJS);
      if (sn != null && sn.typeofEquals('number')) {
        return (sn as JSNumber).toDartInt;
      }
    } catch (_) {}
    return null;
  }

  Future<void> initialize() async {
    _videoElement
      ..autoplay = false
      ..controls = false
      ..playsInline = true;

    if (_hlsFallback == true || await shouldUseHlsLibrary()) {
      _hlsFallback = false;
      try {
        _hls = Hls(
          HlsConfig(
            xhrSetup: (web.XMLHttpRequest xhr, String _) {
              if (headers.isEmpty) {
                return;
              }

              if (headers.containsKey('useCookies')) {
                xhr.withCredentials = true;
              }
              headers.forEach((String key, String value) {
                if (key != 'useCookies') {
                  xhr.setRequestHeader(key, value);
                }
              });
            }.toJS,
          ),
        );
        _hls!.attachMedia(_videoElement);
        _hls!.on(
            'hlsMediaAttached',
            ((String _, JSObject __) {
              _hls!.loadSource(_currentSource);
            }.toJS));
        _hls!.on(
            'hlsError',
            (String _, JSObject data) {
              try {
                final ErrorData _data = data as ErrorData;
                // Verbose: log every hls.js error, fatal or not. Non-fatal
                // errors (frag load timeouts, buffer stalls) precede most
                // fatal failures and are otherwise swallowed silently.
                debugPrint(
                    '[hls] ${_data.fatal ? 'FATAL' : 'warn'} ${_data.type} / ${_data.details}');
                if (_data.fatal) {
                  _eventController.addError(PlatformException(
                    code: _kErrorValueToErrorName[2]!,
                    message: '${_data.type} / ${_data.details}',
                    details: _data.details,
                  ));
                }
              } catch (e) {
                debugPrint('Error parsing hlsError: $e');
              }
            }.toJS);
        // Host renders cues by default; cues are still parsed into a hidden
        // TextTrack so we can forward their text.
        _hls!.subtitleDisplay = _subtitleDisplay;
        _onHlsSubtitleTracksUpdated =
            ((String _, JSObject __) => _subtitleTracksController.add(null))
                .toJS;
        _onHlsSubtitleTrackSwitch = ((String _, JSObject __) {
          _subtitleTracksController.add(null);
          _rewireActiveCueTrack();
        }).toJS;
        _hls!.on(_kHlsSubtitleTracksUpdated, _onHlsSubtitleTracksUpdated!);
        _hls!.on(_kHlsSubtitleTrackSwitch, _onHlsSubtitleTrackSwitch!);
        // Cineseed debug: trace manifest/level loads and per-fragment lifecycle
        // so playback stalls can be tied to a specific segment request. Chatty
        // (one line per fragment), so gated behind the runtime verbose flag.
        if (_hlsVerbose) {
          for (final name in const <String>[
            'hlsManifestParsed',
            'hlsLevelLoaded',
            'hlsFragLoading',
            'hlsFragLoaded',
            'hlsFragBuffered',
          ]) {
            _hls!.on(
                name,
                ((String _, JSObject data) {
                  final sn = _fragSn(data);
                  debugPrint(
                      '[cineseed][HLS] $name${sn != null ? ' sn=$sn' : ''}');
                }).toJS);
          }
        }
        _eventsSubscriptions.add(_videoElement.onCanPlay.listen((dynamic _) {
          _onVideoElementInitialization(_);
          setBuffering(false);
        }));
      } catch (e) {
        throw NoScriptTagException();
      }
    } else {
      _videoElement.src = uri.toString();
      final onDurationChange = (web.Event event) {
        if (_videoElement.duration == 0) {
          return;
        }
        _onVideoElementInitialization(event);
      };
      _eventsSubscriptions.add(_videoElement.onDurationChange.listen(onDurationChange));
    }

    // Needed for Safari iOS 17, which may not send `canplay`.
    _videoElement.onLoadedMetadata.listen(_onVideoElementInitialization);

    _eventsSubscriptions.add(_videoElement.onCanPlayThrough.listen((dynamic _) {
      setBuffering(false);
    }));

    _eventsSubscriptions.add(_videoElement.onPlaying.listen((dynamic _) {
      setBuffering(false);
    }));

    _eventsSubscriptions.add(_videoElement.onWaiting.listen((dynamic _) {
      setBuffering(true);
      _sendBufferingRangesUpdate();
    }));

    // Cineseed debug: <video> element stall/seek transitions — the playback-side
    // counterpart to the hls.js fragment trace above (a freeze shows up here as
    // a `waiting`/`stalled` with no matching `playing` afterwards).
    if (_hlsVerbose) {
      void traceMediaEvent(String name, Stream<web.Event> stream) {
        _eventsSubscriptions.add(stream.listen((web.Event _) => debugPrint(
            '[cineseed][HLS] <video> $name t=${_videoElement.currentTime.toStringAsFixed(2)}')));
      }

      traceMediaEvent('waiting', _videoElement.onWaiting);
      traceMediaEvent('stalled', _videoElement.onStalled);
      traceMediaEvent('seeking', _videoElement.onSeeking);
      traceMediaEvent('seeked', _videoElement.onSeeked);
      traceMediaEvent('playing', _videoElement.onPlaying);
    }

    // The error event fires when some form of error occurs while attempting to load or perform the media.
    _eventsSubscriptions.add(_videoElement.onError.listen((web.Event _) {
      // The Event itself (_) doesn't contain info about the actual error.
      // We need to look at the HTMLMediaElement.error.
      // See: https://developer.mozilla.org/en-US/docs/Web/API/HTMLMediaElement/error
      final web.MediaError error = _videoElement.error!;
      final errorCode = error.code;
      if (_hls == null && _hlsFallback == null && errorCode == 4) {
        // MEDIA_ERR_SRC_NOT_SUPPORTED
        // Native play did not succeed, fallback to hlsjs
        _hlsFallback = true;
        // Cancel all event listeners and re initialize
        for (final sub in _eventsSubscriptions) {
          sub.cancel();
        }
        initialize();
        return;
      }
      setBuffering(false);
      _eventController.addError(PlatformException(
        code: _kErrorValueToErrorName[error.code]!,
        message: error.message != '' ? error.message : _kDefaultErrorMessage,
        details: _kErrorValueToErrorDescription[error.code],
      ));
    }));

    _eventsSubscriptions.add(_videoElement.onPlay.listen((dynamic _) {
      _eventController.add(VideoEvent(
        eventType: VideoEventType.isPlayingStateUpdate,
        isPlaying: true,
      ));
    }));

    _eventsSubscriptions.add(_videoElement.onPause.listen((dynamic _) {
      _eventController.add(VideoEvent(
        eventType: VideoEventType.isPlayingStateUpdate,
        isPlaying: false,
      ));
    }));

    _eventsSubscriptions.add(_videoElement.onEnded.listen((dynamic _) {
      // hls.js calls MediaSource.endOfStream() while swapping sources, which
      // makes some browsers (Firefox) fire `ended`; don't report completion
      // for a mid-switch teardown.
      if (_isSwitching) return;
      setBuffering(false);
      _eventController.add(VideoEvent(eventType: VideoEventType.completed));
    }));
  }

  /// Attempts to play the video.
  ///
  /// If this method is called programmatically (without user interaction), it
  /// might fail unless the video is completely muted (or it has no Audio tracks).
  ///
  /// When called from some user interaction (a tap on a button), the above
  /// limitation should disappear.
  Future<void> play() {
    return _videoElement.play().toDart.catchError((Object e) {
      // play() attempts to begin playback of the media. It returns
      // a Promise which can get rejected in case of failure to begin
      // playback for any reason, such as permission issues.
      // The rejection handler is called with a DOMException.
      // See: https://developer.mozilla.org/en-US/docs/Web/API/HTMLMediaElement/play
      final web.DOMException exception = e as web.DOMException;
      // AbortError means a pause() or a source change landed while this
      // play() was still pending (e.g. buffering after a far seek): the
      // element simply stays paused. Forwarding it would make
      // VideoPlayerController mark the player erroneous for good, so it is
      // dropped here; every other rejection (NotAllowedError,
      // NotSupportedError, ...) is still surfaced.
      if (exception.name == 'AbortError') {
        if (_hlsVerbose) {
          debugPrint('[hls] play() aborted: ${exception.message}');
        }
        return null;
      }
      _eventController.addError(PlatformException(
        code: exception.name,
        message: exception.message,
      ));
      return null;
    }, test: (Object e) => e is web.DOMException);
  }

  /// Pauses the video in the current position.
  void pause() {
    _videoElement.pause();
  }

  /// Controls whether the video should start again after it finishes.
  // ignore: use_setters_to_change_properties
  void setLooping(bool value) {
    _videoElement.loop = value;
  }

  /// Sets the volume at which the media will be played.
  ///
  /// Values must fall between 0 and 1, where 0 is muted and 1 is the loudest.
  ///
  /// When volume is set to 0, the `muted` property is also applied to the
  /// [html.VideoElement]. This is required for auto-play on the web.
  void setVolume(double volume) {
    assert(volume >= 0 && volume <= 1);

    // TODO(ditman): Do we need to expose a "muted" API?
    // https://github.com/flutter/flutter/issues/60721
    _videoElement.muted = !(volume > 0.0);
    _videoElement.volume = volume;
  }

  /// Sets the playback `speed`.
  ///
  /// A `speed` of 1.0 is "normal speed," values lower than 1.0 make the media
  /// play slower than normal, higher values make it play faster.
  ///
  /// `speed` cannot be negative.
  ///
  /// The audio is muted when the fast forward or slow motion is outside a useful
  /// range (for example, Gecko mutes the sound outside the range 0.25 to 4.0).
  ///
  /// The pitch of the audio is corrected by default.
  void setPlaybackSpeed(double speed) {
    assert(speed > 0);

    _videoElement.playbackRate = speed;
  }

  /// Moves the playback head to a new `position`.
  ///
  /// `position` cannot be negative.
  void seekTo(Duration position) {
    assert(!position.isNegative);

    // Don't seek if video is already at target position.
    //
    // This is needed because the core plugin will pause and seek to the end of
    // the video when it finishes, and that causes an infinite loop of `ended`
    // events on the web.
    //
    // See: https://github.com/flutter/flutter/issues/77674
    if (position == _videoElementCurrentTime) {
      return;
    }

    _videoElement.currentTime = position.inMilliseconds.toDouble() / 1000;
  }

  /// Returns the current playback head position as a [Duration].
  Duration getPosition() {
    _sendBufferingRangesUpdate();
    return _videoElementCurrentTime;
  }

  /// Returns the currentTime of the underlying video element.
  Duration get _videoElementCurrentTime {
    return Duration(milliseconds: (_videoElement.currentTime * 1000).round());
  }

  /// Disposes of the current [html.VideoElement].
  void dispose() {
    _videoElement.removeAttribute('src');
    if (_onContextMenu != null) {
      _videoElement.removeEventListener('contextmenu', _onContextMenu);
      _onContextMenu = null;
    }
    _videoElement.load();
    _activeCueTrack?.removeEventListener('cuechange', _cueChangeListener);
    _activeCueTrack = null;
    final hls = _hls;
    if (hls != null) {
      if (_onHlsSubtitleTracksUpdated != null) {
        hls.off(_kHlsSubtitleTracksUpdated, _onHlsSubtitleTracksUpdated!);
      }
      if (_onHlsSubtitleTrackSwitch != null) {
        hls.off(_kHlsSubtitleTrackSwitch, _onHlsSubtitleTrackSwitch!);
      }
    }
    _subtitleCueController.close();
    _subtitleTracksController.close();
    _hls?.stopLoad();
    for (final sub in _eventsSubscriptions) {
      sub.cancel();
    }
  }

  // Sends an [VideoEventType.initialized] [VideoEvent] with info about the wrapped video.
  void _sendInitialized() {
    final Duration? duration = convertNumVideoDurationToPluginDuration(_videoElement.duration);

    Size? size = _videoElement.videoHeight.isFinite
        ? Size(
            _videoElement.videoWidth.toDouble(),
            _videoElement.videoHeight.toDouble(),
          )
        : null;
    if (size == null || size.height == 0 || size.width == 0) {
      size = const Size(1920, 1080);
    }

    _eventController.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: duration,
        size: size,
      ),
    );
  }

  /// Caches the current "buffering" state of the video.
  ///
  /// If the current buffering state is different from the previous one
  /// ([_isBuffering]), this dispatches a [VideoEvent].
  @visibleForTesting
  void setBuffering(bool buffering) {
    if (_isBuffering != buffering) {
      _isBuffering = buffering;
      _eventController.add(VideoEvent(
        eventType: _isBuffering ? VideoEventType.bufferingStart : VideoEventType.bufferingEnd,
      ));
    }
  }

  // Broadcasts the [html.VideoElement.buffered] status through the [events] stream.
  void _sendBufferingRangesUpdate() {
    _eventController.add(VideoEvent(
      buffered: _toDurationRange(_videoElement.buffered),
      eventType: VideoEventType.bufferingUpdate,
    ));
  }

  // Converts from [html.TimeRanges] to our own List<DurationRange>.
  List<DurationRange> _toDurationRange(web.TimeRanges buffered) {
    final List<DurationRange> durationRange = <DurationRange>[];
    for (int i = 0; i < buffered.length; i++) {
      durationRange.add(DurationRange(
        Duration(milliseconds: (buffered.start(i) * 1000).round()),
        Duration(milliseconds: (buffered.end(i) * 1000).round()),
      ));
    }
    return durationRange;
  }

  bool canPlayHlsNatively() {
    bool canPlayHls = false;
    try {
      final String canPlayType = _videoElement.canPlayType('application/vnd.apple.mpegurl');
      canPlayHls = canPlayType != '';
    } catch (e) {}
    return canPlayHls;
  }

  Future<bool> shouldUseHlsLibrary() async {
    return isSupported() && (uri.toString().contains('m3u8') || await _testIfM3u8());
  }

  Future<bool> _testIfM3u8() async {
    try {
      final Map<String, String> headers = Map<String, String>.of(this.headers);
      if (headers.containsKey('Range') || headers.containsKey('range')) {
        final List<int> range = (headers['Range'] ?? headers['range'])!
            .split('bytes')[1]
            .split('-')
            .map((String e) => int.parse(e))
            .toList();
        range[1] = min(range[0] + 1023, range[1]);
        headers['Range'] = 'bytes=${range[0]}-${range[1]}';
      } else {
        headers['Range'] = 'bytes=0-1023';
      }
      final http.Response response = await http.get(Uri.parse(this.uri), headers: headers);
      final String body = response.body;
      if (!body.contains('#EXTM3U')) {
        return false;
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Sets options
  Future<void> setOptions(VideoPlayerWebOptions options) async {
    // In case this method is called multiple times, reset options.
    _resetOptions();

    if (options.controls.enabled) {
      _videoElement.controls = true;
      final String controlsList = options.controls.controlsList;
      if (controlsList.isNotEmpty) {
        _videoElement.controlsList = controlsList.toJS;
      }

      if (!options.controls.allowPictureInPicture) {
        _videoElement.disablePictureInPicture = true;
      }
    }

    if (!options.allowContextMenu) {
      _onContextMenu = ((web.Event event) => event.preventDefault()).toJS;
      _videoElement.addEventListener('contextmenu', _onContextMenu);
    }

    if (!options.allowRemotePlayback) {
      _videoElement.disableRemotePlayback = true;
    } else {
      final bool isSafari = web.window.navigator.userAgent.contains('Safari');

      if (isSafari) {
        debugPrint('Warning: Enabling remote playback on Safari may prevent media from loading properly.');
      }
    }

    if (options.poster != null) {
      _videoElement.poster = options.poster!.toString();
    }
  }

  // Handler to mark (and broadcast) when this player [_isInitialized].
  //
  // (Used as a JS event handler for "canplay" and "loadedmetadata")
  //
  // This function can be called multiple times by different JS Events, but it'll
  // only broadcast an "initialized" event the first time it's called, and ignore
  // the rest of the calls.
  void _onVideoElementInitialization(Object? _) {
    if (!_isInitialized) {
      _isInitialized = true;
      _sendInitialized();
    }
  }

  void _resetOptions() {
    _videoElement.controls = false;
    _videoElement.removeAttribute('controlsList');
    _videoElement.removeAttribute('disablePictureInPicture');
    if (_onContextMenu != null) {
      _videoElement.removeEventListener('contextmenu', _onContextMenu);
      _onContextMenu = null;
    }
    _videoElement.removeAttribute('disableRemotePlayback');
  }
}
