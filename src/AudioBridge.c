#include "AudioBridge.h"
#include "RingBuffer.h"

#include <AudioToolbox/AudioToolbox.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

// ---------------------------------------------------------------------------
// Tuning
// ---------------------------------------------------------------------------
#define MA_BUFFER_FRAMES      256u    // requested device buffer size
#define MA_MAX_SLICE          4096u   // hard ceiling for one render slice
#define MA_RING_FRAMES        16384u  // ~370 ms at 44.1k; rounded to pow2
#define MA_TARGET_FILL        1536u   // steady-state backlog, ~35 ms at 44.1k

// Drift control. Clamped to 0.2% so any correction is well below the
// ~0.6% threshold where pitch change becomes audible.
#define MA_DRIFT_GAIN         2.0e-6
#define MA_DRIFT_MAX          0.002

struct MacAmpEngine {
    AudioUnit   inUnit;
    AudioUnit   outUnit;

    RingBuffer  ring;

    AudioBufferList *inList;     // preallocated, reused every input callback
    float           *ilv;        // interleave scratch, MA_MAX_SLICE * 2 floats

    double      inRate;
    double      outRate;
    UInt32      inChannels;      // 1 or 2, as the device actually provides

    double      phase;           // fractional read position into the ring

    _Atomic int      running;
    _Atomic uint32_t volBits;    // float bit-punned, for lock-free UI updates
    _Atomic uint32_t underruns;
    _Atomic uint32_t overruns;
    _Atomic uint32_t fillSnapshot;
};

static inline float vol_of(const MacAmpEngine *e) {
    uint32_t b = atomic_load_explicit(&e->volBits, memory_order_relaxed);
    float f; memcpy(&f, &b, sizeof f); return f;
}

// ---------------------------------------------------------------------------
// Input callback: pull from the input unit, interleave, push into the ring.
// Realtime thread. No allocation, no locks, no Obj-C, no Swift.
// ---------------------------------------------------------------------------
static OSStatus inputProc(void *ref,
                          AudioUnitRenderActionFlags *flags,
                          const AudioTimeStamp *ts,
                          UInt32 bus, UInt32 nFrames,
                          AudioBufferList *unused)
{
    (void)unused;
    MacAmpEngine *e = (MacAmpEngine *)ref;
    if (nFrames > MA_MAX_SLICE) return noErr;

    // mDataByteSize is clobbered by each render; restore it every time.
    for (UInt32 b = 0; b < e->inList->mNumberBuffers; b++) {
        e->inList->mBuffers[b].mDataByteSize = nFrames * (UInt32)sizeof(float);
    }

    OSStatus st = AudioUnitRender(e->inUnit, flags, ts, bus, nFrames, e->inList);
    if (st != noErr) return noErr;   // drop the slice; the ring will underrun

    const float *L = (const float *)e->inList->mBuffers[0].mData;
    const float *R = (e->inChannels > 1 && e->inList->mNumberBuffers > 1)
                   ? (const float *)e->inList->mBuffers[1].mData
                   : L;                        // mono source feeds both sides

    for (UInt32 i = 0; i < nFrames; i++) {
        e->ilv[i * 2 + 0] = L[i];
        e->ilv[i * 2 + 1] = R[i];
    }

    uint32_t wrote = rb_write(&e->ring, e->ilv, nFrames);
    if (wrote < nFrames) {
        atomic_fetch_add_explicit(&e->overruns, 1, memory_order_relaxed);
    }
    return noErr;
}

// Catmull-Rom / cubic Hermite. Transparent at ratio ~1.0 and materially
// cleaner than linear when the two devices sit at different rates.
static inline float hermite(float y0, float y1, float y2, float y3, float t) {
    float c0 = y1;
    float c1 = 0.5f * (y2 - y0);
    float c2 = y0 - 2.5f * y1 + 2.0f * y2 - 0.5f * y3;
    float c3 = 0.5f * (y3 - y0) + 1.5f * (y1 - y2);
    return ((c3 * t + c2) * t + c1) * t + c0;
}

// ---------------------------------------------------------------------------
// Output callback: fractional read out of the ring, drift-corrected.
// ---------------------------------------------------------------------------
static OSStatus outputProc(void *ref,
                           AudioUnitRenderActionFlags *flags,
                           const AudioTimeStamp *ts,
                           UInt32 bus, UInt32 nFrames,
                           AudioBufferList *ioData)
{
    (void)flags; (void)ts; (void)bus;
    MacAmpEngine *e = (MacAmpEngine *)ref;

    float *outL = (float *)ioData->mBuffers[0].mData;
    float *outR = (ioData->mNumberBuffers > 1)
                ? (float *)ioData->mBuffers[1].mData : NULL;

    if (!atomic_load_explicit(&e->running, memory_order_relaxed)) {
        for (UInt32 b = 0; b < ioData->mNumberBuffers; b++)
            memset(ioData->mBuffers[b].mData, 0, ioData->mBuffers[b].mDataByteSize);
        return noErr;
    }

    uint32_t avail = rb_available(&e->ring);
    atomic_store_explicit(&e->fillSnapshot, avail, memory_order_relaxed);

    // Slow control loop: nudge the resample ratio so the backlog converges on
    // MA_TARGET_FILL. This is what absorbs the two devices' clock drift.
    double err  = (double)avail - (double)MA_TARGET_FILL;
    double corr = 1.0 + err * MA_DRIFT_GAIN;
    if (corr > 1.0 + MA_DRIFT_MAX) corr = 1.0 + MA_DRIFT_MAX;
    if (corr < 1.0 - MA_DRIFT_MAX) corr = 1.0 - MA_DRIFT_MAX;
    const double inc = (e->inRate / e->outRate) * corr;

    const float vol = vol_of(e);
    double phase = e->phase;

    // Frames the ring must hold for this whole slice, plus the 3-frame lookahead
    // cubic interpolation needs.
    double needed = phase + inc * (double)nFrames + 3.0;
    if ((double)avail < needed) {
        // Underrun: emit silence rather than a click, and let the next callback
        // recover with a fuller buffer.
        for (UInt32 b = 0; b < ioData->mNumberBuffers; b++)
            memset(ioData->mBuffers[b].mData, 0, ioData->mBuffers[b].mDataByteSize);
        atomic_fetch_add_explicit(&e->underruns, 1, memory_order_relaxed);
        return noErr;
    }

    for (UInt32 i = 0; i < nFrames; i++) {
        uint32_t idx = (uint32_t)phase;
        float    t   = (float)(phase - (double)idx);

        float l0,r0,l1,r1,l2,r2,l3,r3;
        rb_peek_frame(&e->ring, idx + 0, &l0, &r0);
        rb_peek_frame(&e->ring, idx + 1, &l1, &r1);
        rb_peek_frame(&e->ring, idx + 2, &l2, &r2);
        rb_peek_frame(&e->ring, idx + 3, &l3, &r3);

        float sL = hermite(l0, l1, l2, l3, t) * vol;
        float sR = hermite(r0, r1, r2, r3, t) * vol;

        outL[i] = sL;
        if (outR) outR[i] = sR;
        phase += inc;
    }

    // Retire whole frames we've consumed; carry the fraction to next callback.
    uint32_t consumed = (uint32_t)phase;
    if (consumed) { rb_advance(&e->ring, consumed); phase -= (double)consumed; }
    e->phase = phase;

    // Any channels beyond stereo get silence rather than garbage.
    for (UInt32 b = 2; b < ioData->mNumberBuffers; b++)
        memset(ioData->mBuffers[b].mData, 0, ioData->mBuffers[b].mDataByteSize);

    return noErr;
}

// ---------------------------------------------------------------------------
// Device helpers
// ---------------------------------------------------------------------------
static double device_rate(AudioDeviceID dev) {
    Float64 sr = 0; UInt32 sz = sizeof sr;
    AudioObjectPropertyAddress a = { kAudioDevicePropertyNominalSampleRate,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &sr) != noErr) return 0;
    return (double)sr;
}

static UInt32 device_channels(AudioDeviceID dev, int input) {
    AudioObjectPropertyAddress a = { kAudioDevicePropertyStreamConfiguration,
                                     input ? kAudioObjectPropertyScopeInput
                                           : kAudioObjectPropertyScopeOutput,
                                     kAudioObjectPropertyElementMain };
    UInt32 sz = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &sz) != noErr || sz == 0) return 0;
    AudioBufferList *bl = (AudioBufferList *)malloc(sz);
    if (!bl) return 0;
    UInt32 ch = 0;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, bl) == noErr) {
        for (UInt32 i = 0; i < bl->mNumberBuffers; i++) ch += bl->mBuffers[i].mNumberChannels;
    }
    free(bl);
    return ch;
}

// Best-effort. A device that refuses the size just keeps its own.
static void try_set_buffer_size(AudioDeviceID dev, UInt32 frames) {
    AudioObjectPropertyAddress a = { kAudioDevicePropertyBufferFrameSize,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain };
    AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof frames, &frames);
}

static AudioStreamBasicDescription pcm_format(double rate, UInt32 channels) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof f);
    f.mSampleRate       = rate;
    f.mFormatID         = kAudioFormatLinearPCM;
    f.mFormatFlags      = kAudioFormatFlagIsFloat
                        | kAudioFormatFlagIsPacked
                        | kAudioFormatFlagIsNonInterleaved;
    f.mBitsPerChannel   = 32;
    f.mChannelsPerFrame = channels;
    f.mFramesPerPacket  = 1;
    f.mBytesPerFrame    = 4;   // per buffer: non-interleaved
    f.mBytesPerPacket   = 4;
    return f;
}

static AudioUnit new_halunit(void) {
    AudioComponentDescription d;
    memset(&d, 0, sizeof d);
    d.componentType         = kAudioUnitType_Output;
    d.componentSubType      = kAudioUnitSubType_HALOutput;
    d.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent c = AudioComponentFindNext(NULL, &d);
    if (!c) return NULL;
    AudioUnit u = NULL;
    if (AudioComponentInstanceNew(c, &u) != noErr) return NULL;
    return u;
}

#define FAIL(fmt, ...) do { \
    snprintf(errBuf, errBufLen, fmt, ##__VA_ARGS__); \
    macamp_stop(e); return -1; } while (0)

#define CHK(call, fmt, ...) do { \
    OSStatus _s = (call); \
    if (_s != noErr) { snprintf(errBuf, errBufLen, fmt " (OSStatus %d)", ##__VA_ARGS__, (int)_s); \
                       macamp_stop(e); return (int)_s; } } while (0)

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------
MacAmpEngine *macamp_create(void) {
    MacAmpEngine *e = (MacAmpEngine *)calloc(1, sizeof *e);
    if (!e) return NULL;
    float one = 1.0f; uint32_t bits;
    memcpy(&bits, &one, sizeof bits);
    atomic_store(&e->volBits, bits);
    return e;
}

int macamp_start(MacAmpEngine *e, AudioDeviceID inDev, AudioDeviceID outDev,
                 char *errBuf, size_t errBufLen)
{
    if (!e) return -1;
    macamp_stop(e);
    errBuf[0] = '\0';

    UInt32 enable = 1, disable = 0;
    UInt32 maxSlice = MA_MAX_SLICE;

    e->inChannels = device_channels(inDev, 1);
    if (e->inChannels == 0) FAIL("Selected input device reports no input channels.");
    if (e->inChannels > 2) e->inChannels = 2;

    UInt32 outCh = device_channels(outDev, 0);
    if (outCh == 0) FAIL("Selected output device reports no output channels.");

    try_set_buffer_size(inDev,  MA_BUFFER_FRAMES);
    try_set_buffer_size(outDev, MA_BUFFER_FRAMES);

    e->inRate  = device_rate(inDev);
    e->outRate = device_rate(outDev);
    if (e->inRate <= 0 || e->outRate <= 0) FAIL("Could not read device sample rates.");

    // ---- input unit -------------------------------------------------------
    e->inUnit = new_halunit();
    if (!e->inUnit) FAIL("Could not instantiate the input audio unit.");

    // EnableIO must precede setting the device, and both must precede formats.
    CHK(AudioUnitSetProperty(e->inUnit, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1, &enable, sizeof enable),
        "Enabling capture on the input unit failed");
    CHK(AudioUnitSetProperty(e->inUnit, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output, 0, &disable, sizeof disable),
        "Disabling playback on the input unit failed");
    CHK(AudioUnitSetProperty(e->inUnit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &inDev, sizeof inDev),
        "Binding the input unit to the selected device failed");

    AudioStreamBasicDescription inFmt = pcm_format(e->inRate, e->inChannels);
    CHK(AudioUnitSetProperty(e->inUnit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 1, &inFmt, sizeof inFmt),
        "Input device rejected 32-bit float capture format");
    CHK(AudioUnitSetProperty(e->inUnit, kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global, 0, &maxSlice, sizeof maxSlice),
        "Setting max frames per slice on the input unit failed");

    AURenderCallbackStruct icb = { inputProc, e };
    CHK(AudioUnitSetProperty(e->inUnit, kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global, 0, &icb, sizeof icb),
        "Installing the input callback failed");
    CHK(AudioUnitInitialize(e->inUnit), "Initializing the input unit failed");

    // ---- buffers ----------------------------------------------------------
    size_t listBytes = sizeof(AudioBufferList) + sizeof(AudioBuffer) * 2;
    e->inList = (AudioBufferList *)calloc(1, listBytes);
    if (!e->inList) FAIL("Out of memory allocating the capture buffer list.");
    e->inList->mNumberBuffers = e->inChannels;
    for (UInt32 b = 0; b < e->inChannels; b++) {
        e->inList->mBuffers[b].mNumberChannels = 1;
        e->inList->mBuffers[b].mDataByteSize   = MA_MAX_SLICE * sizeof(float);
        e->inList->mBuffers[b].mData           = calloc(MA_MAX_SLICE, sizeof(float));
        if (!e->inList->mBuffers[b].mData) FAIL("Out of memory allocating capture buffers.");
    }
    e->ilv = (float *)calloc(MA_MAX_SLICE * 2, sizeof(float));
    if (!e->ilv) FAIL("Out of memory allocating the interleave buffer.");
    if (!rb_init(&e->ring, MA_RING_FRAMES)) FAIL("Out of memory allocating the ring buffer.");
    e->phase = 0.0;

    // ---- output unit ------------------------------------------------------
    e->outUnit = new_halunit();
    if (!e->outUnit) FAIL("Could not instantiate the output audio unit.");

    CHK(AudioUnitSetProperty(e->outUnit, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output, 0, &enable, sizeof enable),
        "Enabling playback on the output unit failed");
    CHK(AudioUnitSetProperty(e->outUnit, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1, &disable, sizeof disable),
        "Disabling capture on the output unit failed");
    CHK(AudioUnitSetProperty(e->outUnit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &outDev, sizeof outDev),
        "Binding the output unit to the selected device failed");

    AudioStreamBasicDescription outFmt = pcm_format(e->outRate, outCh > 2 ? outCh : 2);
    CHK(AudioUnitSetProperty(e->outUnit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0, &outFmt, sizeof outFmt),
        "Output device rejected 32-bit float playback format");
    CHK(AudioUnitSetProperty(e->outUnit, kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global, 0, &maxSlice, sizeof maxSlice),
        "Setting max frames per slice on the output unit failed");

    AURenderCallbackStruct ocb = { outputProc, e };
    CHK(AudioUnitSetProperty(e->outUnit, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0, &ocb, sizeof ocb),
        "Installing the render callback failed");
    CHK(AudioUnitInitialize(e->outUnit), "Initializing the output unit failed");

    atomic_store(&e->underruns, 0);
    atomic_store(&e->overruns, 0);
    atomic_store(&e->running, 1);

    // Capture first so the ring has a backlog before playback pulls on it.
    CHK(AudioOutputUnitStart(e->inUnit),  "Starting capture failed");
    CHK(AudioOutputUnitStart(e->outUnit), "Starting playback failed");
    return 0;
}

void macamp_stop(MacAmpEngine *e) {
    if (!e) return;
    atomic_store(&e->running, 0);

    if (e->outUnit) {
        AudioOutputUnitStop(e->outUnit);
        AudioUnitUninitialize(e->outUnit);
        AudioComponentInstanceDispose(e->outUnit);
        e->outUnit = NULL;
    }
    if (e->inUnit) {
        AudioOutputUnitStop(e->inUnit);
        AudioUnitUninitialize(e->inUnit);
        AudioComponentInstanceDispose(e->inUnit);
        e->inUnit = NULL;
    }
    if (e->inList) {
        for (UInt32 b = 0; b < e->inList->mNumberBuffers; b++) free(e->inList->mBuffers[b].mData);
        free(e->inList);
        e->inList = NULL;
    }
    free(e->ilv); e->ilv = NULL;
    rb_free(&e->ring);
    e->phase = 0.0;
}

void macamp_destroy(MacAmpEngine *e) { if (e) { macamp_stop(e); free(e); } }

int macamp_is_running(const MacAmpEngine *e) {
    return e ? atomic_load_explicit(&e->running, memory_order_relaxed) : 0;
}

void macamp_set_volume(MacAmpEngine *e, float v) {
    if (!e) return;
    if (v < 0.0f) v = 0.0f;
    uint32_t bits; memcpy(&bits, &v, sizeof bits);
    atomic_store_explicit(&e->volBits, bits, memory_order_relaxed);
}

float macamp_get_volume(const MacAmpEngine *e) { return e ? vol_of(e) : 0.0f; }

double macamp_latency_ms(const MacAmpEngine *e) {
    if (!e || e->inRate <= 0) return 0.0;
    uint32_t fill = atomic_load_explicit(&e->fillSnapshot, memory_order_relaxed);
    double ringMs = (double)fill * 1000.0 / e->inRate;
    double devMs  = (double)MA_BUFFER_FRAMES * 1000.0 / e->inRate
                  + (double)MA_BUFFER_FRAMES * 1000.0 / (e->outRate > 0 ? e->outRate : e->inRate);
    return ringMs + devMs;
}

uint32_t macamp_underruns(const MacAmpEngine *e) {
    return e ? atomic_load_explicit(&e->underruns, memory_order_relaxed) : 0;
}
uint32_t macamp_overruns(const MacAmpEngine *e) {
    return e ? atomic_load_explicit(&e->overruns, memory_order_relaxed) : 0;
}
double macamp_input_rate(const MacAmpEngine *e)  { return e ? e->inRate  : 0.0; }
double macamp_output_rate(const MacAmpEngine *e) { return e ? e->outRate : 0.0; }
