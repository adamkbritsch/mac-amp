// AudioBridge.h -- the realtime audio path, in C.
//
// Deliberately not Swift: both render callbacks run on CoreAudio realtime
// threads with a hard deadline. ARC retain/release, allocation, locks, and
// Swift's exclusivity checks are all unsafe there. Keeping this in C means the
// realtime path provably contains no Swift runtime.
#ifndef MACAMP_AUDIOBRIDGE_H
#define MACAMP_AUDIOBRIDGE_H

#include <CoreAudio/CoreAudio.h>
#include <stdint.h>

typedef struct MacAmpEngine MacAmpEngine;

MacAmpEngine *macamp_create(void);
void          macamp_destroy(MacAmpEngine *e);

// Starts monitoring inputDevice -> outputDevice. Returns 0 on success, or an
// OSStatus. On failure `errBuf` receives a human-readable reason.
int  macamp_start(MacAmpEngine *e,
                  AudioDeviceID inputDevice,
                  AudioDeviceID outputDevice,
                  char *errBuf, size_t errBufLen);

void macamp_stop(MacAmpEngine *e);
int  macamp_is_running(const MacAmpEngine *e);

// 0.0 .. 1.0+, applied on the output thread. Atomic, safe from the UI thread.
void  macamp_set_volume(MacAmpEngine *e, float vol);
float macamp_get_volume(const MacAmpEngine *e);

// Diagnostics, read from the UI thread.
double   macamp_latency_ms(const MacAmpEngine *e);
uint32_t macamp_underruns(const MacAmpEngine *e);
uint32_t macamp_overruns(const MacAmpEngine *e);
double   macamp_input_rate(const MacAmpEngine *e);
double   macamp_output_rate(const MacAmpEngine *e);

#endif
