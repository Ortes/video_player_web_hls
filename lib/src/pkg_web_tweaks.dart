// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart' as web;

/// Adds a "disablePictureInPicture" setter to [web.HTMLVideoElement]s.
extension NonStandardSettersOnVideoElement on web.HTMLVideoElement {
  external set disablePictureInPicture(JSBoolean disabled);
}

/// Adds a "disableRemotePlayback" and "controlsList" setters to [web.HTMLMediaElement]s.
extension NonStandardSettersOnMediaElement on web.HTMLMediaElement {
  external set disableRemotePlayback(JSBoolean disabled);
  external set controlsList(JSString? controlsList);
}

/// Reads "audioTracks" only where it exists: Safari ships it, Chromium and Firefox keep it behind a flag.
extension OptionalAudioTracksOnMediaElement on web.HTMLMediaElement {
  List<web.AudioTrack> get audioTrackList {
    if (!has('audioTracks')) {
      return const <web.AudioTrack>[];
    }
    final web.AudioTrackList tracks = audioTracks;
    return [for (int i = 0; i < tracks.length; i++) tracks.getProperty<web.AudioTrack>(i.toJS)];
  }
}
