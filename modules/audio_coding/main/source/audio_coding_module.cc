/*
 *  Copyright (c) 2012 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "webrtc/modules/audio_coding/main/interface/audio_coding_module.h"

#include "webrtc/common_types.h"
#include "webrtc/modules/audio_coding/main/source/acm_codec_database.h"
#include "webrtc/modules/audio_coding/main/source/acm_dtmf_detection.h"
#include "webrtc/modules/audio_coding/main/source/audio_coding_module_impl.h"
#include "webrtc/system_wrappers/interface/trace.h"

namespace webrtc {

// Create module
AudioCodingModule* AudioCodingModule::Create(const WebRtc_Word32 id) {
  return new AudioCodingModuleImpl(id);
}

// Destroy module
void AudioCodingModule::Destroy(AudioCodingModule* module) {
  delete static_cast<AudioCodingModuleImpl*>(module);
}

// Get number of supported codecs
WebRtc_UWord8 AudioCodingModule::NumberOfCodecs() {
  return static_cast<WebRtc_UWord8>(ACMCodecDB::kNumCodecs);
}

// Get supported codec param with id
WebRtc_Word32 AudioCodingModule::Codec(WebRtc_UWord8 list_id,
                                       CodecInst* codec) {
  // Get the codec settings for the codec with the given list ID
  return ACMCodecDB::Codec(list_id, codec);
}

// Get supported codec Param with name, frequency and number of channels.
WebRtc_Word32 AudioCodingModule::Codec(const char* payload_name,
                                       CodecInst* codec, int sampling_freq_hz,
                                       int channels) {
  int codec_id;

  // Get the id of the codec from the database.
  codec_id = ACMCodecDB::CodecId(payload_name, sampling_freq_hz, channels);
  if (codec_id < 0) {
    // We couldn't find a matching codec, set the parameterss to unacceptable
    // values and return.
    codec->plname[0] = '\0';
    codec->pltype = -1;
    codec->pacsize = 0;
    codec->rate = 0;
    codec->plfreq = 0;
    return -1;
  }

  // Get default codec settings.
  ACMCodecDB::Codec(codec_id, codec);

  // Keep the number of channels from the function call. For most codecs it
  // will be the same value as in defaul codec settings, but not for all.
  codec->channels = channels;

  return 0;
}

// Get supported codec Index with name, frequency and number of channels.
WebRtc_Word32 AudioCodingModule::Codec(const char* payload_name,
                                       int sampling_freq_hz, int channels) {
  return ACMCodecDB::CodecId(payload_name, sampling_freq_hz, channels);
}

// Checks the validity of the parameters of the given codec
bool AudioCodingModule::IsCodecValid(const CodecInst& codec) {
  int mirror_id;

  int codec_number = ACMCodecDB::CodecNumber(&codec, &mirror_id);

  if (codec_number < 0) {
    WEBRTC_TRACE(webrtc::kTraceError, webrtc::kTraceAudioCoding, -1,
                 "Invalid codec settings.");
    return false;
  } else {
    return true;
  }
}

}  // namespace webrtc
