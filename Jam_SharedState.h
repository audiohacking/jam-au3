// Copyright 2026 Google LLC
#pragma once
#include <atomic>
#include "audio_level_processor.h"

struct JamSharedState {
    std::atomic<bool> midiNotes[128] = {};

    magentart::common::AudioLevelProcessor levelProcessor;

    void pushAudioSamples(const float* left, const float* right, int count) {
        levelProcessor.process_block(left, right, count);
    }

    void noteOn(uint8_t note) {
        if (note < 128) midiNotes[note].store(true, std::memory_order_relaxed);
    }
    void noteOff(uint8_t note) {
        if (note < 128) midiNotes[note].store(false, std::memory_order_relaxed);
    }
};
