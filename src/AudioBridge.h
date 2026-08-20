// AudioBridge.h -- a 4-in / 4-out mixer, in C.
//
// Deliberately not Swift: every render callback runs on a CoreAudio realtime
// thread with a hard deadline. ARC traffic, allocation, locks and Swift's
// exclusivity checks are all unsafe there, so the entire audio path is C and
// the Swift side only ever pokes atomics.
//
// Each input strip owns an AUHAL and a ring buffer. Each output bus owns an
// AUHAL and, per input, its own read cursor and fractional resample phase --
// so one guitar can feed two buses running at different rates off different
// clocks, each drift-corrected independently.
#ifndef MACAMP_AUDIOBRIDGE_H
#define MACAMP_AUDIOBRIDGE_H

#include <CoreAudio/CoreAudio.h>
#include <stdint.h>
#include <stddef.h>

#define MA_MAX_INPUTS  4
#define MA_MAX_OUTPUTS 4

typedef struct MacAmpEngine MacAmpEngine;

/// A strip is fed either by a hardware audio device or by a MIDI instrument.
/// MIDI carries no audio of its own, so a MIDI strip owns a synthesiser
/// (Apple's built-in DLS/General MIDI unit) and renders it into the same ring
/// buffer an audio device would fill. Everything downstream -- gain, pan, gate,
/// routing, metering, resampling -- is identical either way.
typedef enum {
    MA_SRC_AUDIO = 0,
    MA_SRC_MIDI  = 1
} MASourceKind;

MacAmpEngine *macamp_create(void);
void          macamp_destroy(MacAmpEngine *e);

// ---- topology ------------------------------------------------------------
// Devices are attached per slot. Attaching or clearing rebuilds only that
// strip or bus; the rest of the mixer keeps running.
int  macamp_set_input   (MacAmpEngine *e, int slot, AudioDeviceID dev, char *err, size_t errLen);
void macamp_clear_input (MacAmpEngine *e, int slot);
int  macamp_set_output  (MacAmpEngine *e, int bus,  AudioDeviceID dev, char *err, size_t errLen);
void macamp_clear_output(MacAmpEngine *e, int bus);

int  macamp_input_active (const MacAmpEngine *e, int slot);
MASourceKind macamp_input_kind(const MacAmpEngine *e, int slot);

// ---- MIDI instrument strips ----------------------------------------------
/// Turns a slot into a MIDI instrument. `sampleRate` is the synth's internal
/// rate; buses at other rates are resampled exactly as for a hardware input.
int  macamp_set_midi_input(MacAmpEngine *e, int slot, double sampleRate,
                           char *err, size_t errLen);

/// Raw MIDI, from a hardware endpoint or the computer keyboard alike.
void macamp_midi_event(MacAmpEngine *e, int slot,
                       unsigned char status, unsigned char d1, unsigned char d2);

/// General MIDI program (0-127) on channel 0.
void macamp_midi_program(MacAmpEngine *e, int slot, unsigned char program);

/// Silences every sounding note -- the panic button for a stuck note-on.
void macamp_midi_all_notes_off(MacAmpEngine *e, int slot);

/// How many notes are currently held, for the UI.
int  macamp_midi_active_notes(const MacAmpEngine *e, int slot);
int  macamp_output_active(const MacAmpEngine *e, int bus);

// ---- routing matrix ------------------------------------------------------
void macamp_set_route(MacAmpEngine *e, int slot, int bus, int on);
int  macamp_get_route(const MacAmpEngine *e, int slot, int bus);

// ---- per-strip controls (live, lock-free) --------------------------------
void macamp_set_gain(MacAmpEngine *e, int slot, float linear);  // 0..~4
void macamp_set_pan (MacAmpEngine *e, int slot, float pan);     // -1 L .. +1 R
void macamp_set_mute(MacAmpEngine *e, int slot, int on);
void macamp_set_solo(MacAmpEngine *e, int slot, int on);
void macamp_set_gate(MacAmpEngine *e, int slot, int on, float thresholdDb);

float macamp_get_gain(const MacAmpEngine *e, int slot);
float macamp_get_pan (const MacAmpEngine *e, int slot);
int   macamp_get_mute(const MacAmpEngine *e, int slot);
int   macamp_get_solo(const MacAmpEngine *e, int slot);
int   macamp_get_gate(const MacAmpEngine *e, int slot);
float macamp_get_gate_threshold(const MacAmpEngine *e, int slot);

// ---- metering ------------------------------------------------------------
// Peak since last read, post-gain/gate. Reading clears, so the UI decays it.
void macamp_read_peaks(MacAmpEngine *e, int slot, float *outL, float *outR);
int  macamp_gate_open (const MacAmpEngine *e, int slot);

// ---- diagnostics ---------------------------------------------------------
double   macamp_input_rate (const MacAmpEngine *e, int slot);
double   macamp_output_rate(const MacAmpEngine *e, int bus);
double   macamp_latency_ms (const MacAmpEngine *e, int bus);
uint32_t macamp_underruns  (const MacAmpEngine *e, int bus);
/// The bus's current adaptive backlog target, in frames. If this has climbed
/// above MA_TARGET_MIN the machine could not hold the floor.
uint32_t macamp_target_frames(const MacAmpEngine *e, int bus);

#endif
