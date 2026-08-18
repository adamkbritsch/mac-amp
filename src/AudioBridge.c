#include "AudioBridge.h"
#include "RingBuffer.h"

#include <AudioToolbox/AudioToolbox.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

#define MA_BUFFER_FRAMES   256u
#define MA_MAX_SLICE       4096u
#define MA_RING_FRAMES     16384u
#define MA_TARGET_FILL     1536u
#define MA_DRIFT_GAIN      2.0e-6
#define MA_DRIFT_MAX       0.002

// ---------------------------------------------------------------------------
// Float <-> atomic uint32 punning, so the UI thread can set a level without a
// lock and the audio thread can read one without tearing.
// ---------------------------------------------------------------------------
static inline uint32_t f2b(float f) { uint32_t b; memcpy(&b, &f, 4); return b; }
static inline float    b2f(uint32_t b) { float f; memcpy(&f, &b, 4); return f; }
static inline float    ldf(const _Atomic uint32_t *a) {
    return b2f(atomic_load_explicit(a, memory_order_relaxed));
}
static inline void     stf(_Atomic uint32_t *a, float v) {
    atomic_store_explicit(a, f2b(v), memory_order_relaxed);
}

typedef struct {
    AudioUnit        unit;
    AudioDeviceID    dev;
    RingBuffer       ring;
    AudioBufferList *inList;
    float           *ilv;
    double           rate;
    UInt32           channels;

    _Atomic uint32_t gain;        // linear
    _Atomic uint32_t pan;         // -1..+1
    _Atomic int      mute;
    _Atomic int      solo;
    _Atomic int      gateOn;
    _Atomic uint32_t gateThresh;  // dB
    _Atomic uint32_t peakL, peakR;
    _Atomic int      gateOpen;
    _Atomic int      active;

    float            gateEnv;     // input thread only
    float            gateGain;    // input thread only
} InputStrip;

typedef struct {
    struct MacAmpEngine *engine;             // back-pointer, set at creation
    int              index;
    AudioUnit        unit;
    AudioDeviceID    dev;
    double           rate;
    UInt32           channels;
    double           phase[MA_MAX_INPUTS];   // output thread only
    _Atomic uint32_t underruns;
    _Atomic uint32_t fill;
    _Atomic int      active;
} OutputBus;

struct MacAmpEngine {
    InputStrip in[MA_MAX_INPUTS];
    OutputBus  out[MA_MAX_OUTPUTS];
    _Atomic uint32_t routes;    // bit (slot * MA_MAX_OUTPUTS + bus)
    _Atomic int      anySolo;
};

static inline int route_bit(int slot, int bus) { return slot * MA_MAX_OUTPUTS + bus; }

static inline int routed(const MacAmpEngine *e, int slot, int bus) {
    uint32_t r = atomic_load_explicit(&e->routes, memory_order_relaxed);
    return (r >> route_bit(slot, bus)) & 1u;
}

static inline float hermite(float y0, float y1, float y2, float y3, float t) {
    float c0 = y1;
    float c1 = 0.5f * (y2 - y0);
    float c2 = y0 - 2.5f * y1 + 2.0f * y2 - 0.5f * y3;
    float c3 = 0.5f * (y3 - y0) + 1.5f * (y1 - y2);
    return ((c3 * t + c2) * t + c1) * t + c0;
}

// ---------------------------------------------------------------------------
// Input callback: capture -> gate -> gain -> meter -> ring.
// Gain and the gate are applied here so every bus fed by this strip sees the
// same fader, and the meter reflects what is actually being sent.
// ---------------------------------------------------------------------------
static OSStatus inputProc(void *ref, AudioUnitRenderActionFlags *flags,
                          const AudioTimeStamp *ts, UInt32 bus, UInt32 nFrames,
                          AudioBufferList *unused)
{
    (void)unused;
    InputStrip *s = (InputStrip *)ref;
    if (nFrames > MA_MAX_SLICE || !s->inList) return noErr;

    for (UInt32 b = 0; b < s->inList->mNumberBuffers; b++)
        s->inList->mBuffers[b].mDataByteSize = nFrames * (UInt32)sizeof(float);

    if (AudioUnitRender(s->unit, flags, ts, bus, nFrames, s->inList) != noErr) return noErr;

    const float *L = (const float *)s->inList->mBuffers[0].mData;
    const float *R = (s->channels > 1 && s->inList->mNumberBuffers > 1)
                   ? (const float *)s->inList->mBuffers[1].mData : L;

    const float gain     = ldf(&s->gain);
    const int   gateOn   = atomic_load_explicit(&s->gateOn, memory_order_relaxed);
    const float threshDb = ldf(&s->gateThresh);
    const float thresh   = powf(10.0f, threshDb / 20.0f);

    // Fast attack so a note is never clipped at its transient; slow release so
    // the gate does not chatter on a decaying note.
    const float atkCoef = 0.01f;
    const float relCoef = 0.0002f;

    float env = s->gateEnv, gg = s->gateGain;
    float pL = 0.0f, pR = 0.0f;

    for (UInt32 i = 0; i < nFrames; i++) {
        float l = L[i], r = R[i];

        if (gateOn) {
            float a  = fabsf(l) > fabsf(r) ? fabsf(l) : fabsf(r);
            env += (a > env ? atkCoef : relCoef) * (a - env);
            float target = env > thresh ? 1.0f : 0.0f;
            gg += (target > gg ? atkCoef : relCoef) * (target - gg);
            l *= gg; r *= gg;
        } else {
            gg = 1.0f;
        }

        l *= gain; r *= gain;
        s->ilv[i * 2 + 0] = l;
        s->ilv[i * 2 + 1] = r;

        float al = fabsf(l), ar = fabsf(r);
        if (al > pL) pL = al;
        if (ar > pR) pR = ar;
    }
    s->gateEnv = env; s->gateGain = gg;
    atomic_store_explicit(&s->gateOpen, gg > 0.5f, memory_order_relaxed);

    // Peak-hold: the UI clears on read, so a transient cannot be missed
    // between frames.
    if (pL > ldf(&s->peakL)) stf(&s->peakL, pL);
    if (pR > ldf(&s->peakR)) stf(&s->peakR, pR);

    rb_write(&s->ring, s->ilv, nFrames);
    return noErr;
}

// ---------------------------------------------------------------------------
// Output callback: sum every routed, unmuted, un-soloed-out input.
// Each input is read with this bus's own cursor and phase, so two buses on
// different clocks each drift-correct independently.
// ---------------------------------------------------------------------------
static OSStatus outputProc(void *ref, AudioUnitRenderActionFlags *flags,
                           const AudioTimeStamp *ts, UInt32 busNum, UInt32 nFrames,
                           AudioBufferList *ioData)
{
    (void)flags; (void)ts; (void)busNum;
    OutputBus    *o = (OutputBus *)ref;
    MacAmpEngine *e = o->engine;

    float *outL = (float *)ioData->mBuffers[0].mData;
    float *outR = (ioData->mNumberBuffers > 1) ? (float *)ioData->mBuffers[1].mData : NULL;

    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++)
        memset(ioData->mBuffers[b].mData, 0, ioData->mBuffers[b].mDataByteSize);

    if (!atomic_load_explicit(&o->active, memory_order_relaxed)) return noErr;

    const int anySolo = atomic_load_explicit(&e->anySolo, memory_order_relaxed);
    const int bus     = o->index;
    uint32_t  minFill = 0xFFFFFFFFu;
    int       starved = 0;

    for (int i = 0; i < MA_MAX_INPUTS; i++) {
        InputStrip *s = &e->in[i];

        if (!atomic_load_explicit(&s->active, memory_order_relaxed)) continue;
        if (!rb_is_attached(&s->ring, (uint32_t)bus))                continue;

        // Not listening to this input right now? Still move the cursor. The
        // producer paces to the furthest-behind consumer, so a bus parked on
        // an unrouted or muted input would otherwise stall that input's ring
        // for every OTHER bus reading it.
        int listening = routed(e, i, bus)
            && !atomic_load_explicit(&s->mute, memory_order_relaxed)
            && !(anySolo && !atomic_load_explicit(&s->solo, memory_order_relaxed));

        if (!listening) {
            uint32_t a = rb_available(&s->ring, (uint32_t)bus);
            if (a > MA_TARGET_FILL) rb_advance(&s->ring, (uint32_t)bus, a - MA_TARGET_FILL);
            o->phase[i] = 0.0;
            continue;
        }

        uint32_t avail = rb_available(&s->ring, (uint32_t)bus);
        if (avail < minFill) minFill = avail;

        double phase = o->phase[i];

        // Per (input, bus) drift control: this bus's backlog on this input
        // steers this pair's resample ratio, independently of every other pair.
        double err  = (double)avail - (double)MA_TARGET_FILL;
        double corr = 1.0 + err * MA_DRIFT_GAIN;
        if (corr >  1.0 + MA_DRIFT_MAX) corr = 1.0 + MA_DRIFT_MAX;
        if (corr <  1.0 - MA_DRIFT_MAX) corr = 1.0 - MA_DRIFT_MAX;
        double inc = (s->rate / o->rate) * corr;

        if ((double)avail < phase + inc * (double)nFrames + 3.0) {
            // This input is starved. Skip it rather than silencing the bus --
            // one stalled source must not take the whole mix down with it.
            starved = 1;
            continue;
        }

        // Constant-power pan, evaluated once per slice.
        float pan   = ldf(&s->pan);
        if (pan < -1.0f) pan = -1.0f;
        if (pan >  1.0f) pan =  1.0f;
        float ang   = (pan + 1.0f) * 0.25f * (float)M_PI;
        float gL    = cosf(ang), gR = sinf(ang);

        for (UInt32 f = 0; f < nFrames; f++) {
            uint32_t idx = (uint32_t)phase;
            float    t   = (float)(phase - (double)idx);
            float l0,r0,l1,r1,l2,r2,l3,r3;
            rb_peek_frame(&s->ring, (uint32_t)bus, idx + 0, &l0, &r0);
            rb_peek_frame(&s->ring, (uint32_t)bus, idx + 1, &l1, &r1);
            rb_peek_frame(&s->ring, (uint32_t)bus, idx + 2, &l2, &r2);
            rb_peek_frame(&s->ring, (uint32_t)bus, idx + 3, &l3, &r3);

            outL[f] += hermite(l0,l1,l2,l3,t) * gL;
            if (outR) outR[f] += hermite(r0,r1,r2,r3,t) * gR;
            phase += inc;
        }

        uint32_t consumed = (uint32_t)phase;
        if (consumed) { rb_advance(&s->ring, (uint32_t)bus, consumed); phase -= (double)consumed; }
        o->phase[i] = phase;
    }

    // Summing several sources can exceed full scale. A hard clip would be the
    // one genuinely destructive thing this program could do to your ears, so
    // clamp rather than let it wrap.
    for (UInt32 f = 0; f < nFrames; f++) {
        if (outL[f] >  1.0f) outL[f] =  1.0f;
        if (outL[f] < -1.0f) outL[f] = -1.0f;
        if (outR) {
            if (outR[f] >  1.0f) outR[f] =  1.0f;
            if (outR[f] < -1.0f) outR[f] = -1.0f;
        }
    }

    if (starved) atomic_fetch_add_explicit(&o->underruns, 1, memory_order_relaxed);
    atomic_store_explicit(&o->fill, minFill == 0xFFFFFFFFu ? 0 : minFill, memory_order_relaxed);

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
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &sr) != noErr) return 0;
    return (double)sr;
}

static UInt32 device_channels(AudioDeviceID dev, int input) {
    AudioObjectPropertyAddress a = { kAudioDevicePropertyStreamConfiguration,
        input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain };
    UInt32 sz = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &sz) != noErr || !sz) return 0;
    AudioBufferList *bl = (AudioBufferList *)malloc(sz);
    if (!bl) return 0;
    UInt32 ch = 0;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, bl) == noErr)
        for (UInt32 i = 0; i < bl->mNumberBuffers; i++) ch += bl->mBuffers[i].mNumberChannels;
    free(bl);
    return ch;
}

static void try_set_buffer_size(AudioDeviceID dev, UInt32 frames) {
    AudioObjectPropertyAddress a = { kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof frames, &frames);
}

static AudioStreamBasicDescription pcm_format(double rate, UInt32 ch) {
    AudioStreamBasicDescription f; memset(&f, 0, sizeof f);
    f.mSampleRate       = rate;
    f.mFormatID         = kAudioFormatLinearPCM;
    f.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                        | kAudioFormatFlagIsNonInterleaved;
    f.mBitsPerChannel   = 32;
    f.mChannelsPerFrame = ch;
    f.mFramesPerPacket  = 1;
    f.mBytesPerFrame    = 4;
    f.mBytesPerPacket   = 4;
    return f;
}

static AudioUnit new_halunit(void) {
    AudioComponentDescription d; memset(&d, 0, sizeof d);
    d.componentType         = kAudioUnitType_Output;
    d.componentSubType      = kAudioUnitSubType_HALOutput;
    d.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent c = AudioComponentFindNext(NULL, &d);
    if (!c) return NULL;
    AudioUnit u = NULL;
    if (AudioComponentInstanceNew(c, &u) != noErr) return NULL;
    return u;
}

static void recompute_solo(MacAmpEngine *e) {
    int any = 0;
    for (int i = 0; i < MA_MAX_INPUTS; i++)
        if (atomic_load_explicit(&e->in[i].active, memory_order_relaxed) &&
            atomic_load_explicit(&e->in[i].solo,   memory_order_relaxed)) { any = 1; break; }
    atomic_store_explicit(&e->anySolo, any, memory_order_relaxed);
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------
MacAmpEngine *macamp_create(void) {
    MacAmpEngine *e = (MacAmpEngine *)calloc(1, sizeof *e);
    if (!e) return NULL;
    for (int i = 0; i < MA_MAX_INPUTS; i++) {
        stf(&e->in[i].gain, 1.0f);
        stf(&e->in[i].pan,  0.0f);
        stf(&e->in[i].gateThresh, -50.0f);
        e->in[i].gateGain = 1.0f;
    }
    for (int b = 0; b < MA_MAX_OUTPUTS; b++) {
        e->out[b].engine = e;
        e->out[b].index  = b;
    }
    // Sensible default: input 1 goes to bus 1.
    atomic_store_explicit(&e->routes, 1u << route_bit(0, 0), memory_order_relaxed);
    return e;
}

void macamp_clear_input(MacAmpEngine *e, int slot) {
    if (!e || slot < 0 || slot >= MA_MAX_INPUTS) return;
    InputStrip *s = &e->in[slot];
    atomic_store_explicit(&s->active, 0, memory_order_release);

    if (s->unit) {
        AudioOutputUnitStop(s->unit);
        AudioUnitUninitialize(s->unit);
        AudioComponentInstanceDispose(s->unit);
        s->unit = NULL;
    }
    if (s->inList) {
        for (UInt32 b = 0; b < s->inList->mNumberBuffers; b++) free(s->inList->mBuffers[b].mData);
        free(s->inList); s->inList = NULL;
    }
    free(s->ilv); s->ilv = NULL;
    rb_free(&s->ring);
    s->dev = 0; s->rate = 0; s->channels = 0;
    stf(&s->peakL, 0.0f); stf(&s->peakR, 0.0f);
    recompute_solo(e);
}

#define IFAIL(fmt, ...) do { snprintf(err, errLen, fmt, ##__VA_ARGS__); \
                             macamp_clear_input(e, slot); return -1; } while (0)
#define ICHK(call, fmt, ...) do { OSStatus _s = (call); if (_s != noErr) { \
        snprintf(err, errLen, fmt " (OSStatus %d)", ##__VA_ARGS__, (int)_s); \
        macamp_clear_input(e, slot); return (int)_s; } } while (0)

int macamp_set_input(MacAmpEngine *e, int slot, AudioDeviceID dev, char *err, size_t errLen) {
    if (!e || slot < 0 || slot >= MA_MAX_INPUTS) return -1;
    macamp_clear_input(e, slot);
    err[0] = '\0';
    InputStrip *s = &e->in[slot];

    UInt32 ch = device_channels(dev, 1);
    if (!ch) IFAIL("That device reports no input channels.");
    s->channels = ch > 2 ? 2 : ch;

    try_set_buffer_size(dev, MA_BUFFER_FRAMES);
    s->rate = device_rate(dev);
    if (s->rate <= 0) IFAIL("Could not read the input device's sample rate.");
    s->dev = dev;

    UInt32 enable = 1, disable = 0, maxSlice = MA_MAX_SLICE;
    s->unit = new_halunit();
    if (!s->unit) IFAIL("Could not instantiate an input audio unit.");

    ICHK(AudioUnitSetProperty(s->unit, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1, &enable, sizeof enable), "Enabling capture failed");
    ICHK(AudioUnitSetProperty(s->unit, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output, 0, &disable, sizeof disable), "Disabling playback failed");
    ICHK(AudioUnitSetProperty(s->unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &dev, sizeof dev), "Binding the input device failed");

    AudioStreamBasicDescription f = pcm_format(s->rate, s->channels);
    ICHK(AudioUnitSetProperty(s->unit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 1, &f, sizeof f), "Device rejected float capture format");
    ICHK(AudioUnitSetProperty(s->unit, kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global, 0, &maxSlice, sizeof maxSlice), "Setting slice size failed");

    AURenderCallbackStruct cb = { inputProc, s };
    ICHK(AudioUnitSetProperty(s->unit, kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global, 0, &cb, sizeof cb), "Installing the input callback failed");
    ICHK(AudioUnitInitialize(s->unit), "Initializing the input unit failed");

    size_t listBytes = sizeof(AudioBufferList) + sizeof(AudioBuffer) * 2;
    s->inList = (AudioBufferList *)calloc(1, listBytes);
    if (!s->inList) IFAIL("Out of memory.");
    s->inList->mNumberBuffers = s->channels;
    for (UInt32 b = 0; b < s->channels; b++) {
        s->inList->mBuffers[b].mNumberChannels = 1;
        s->inList->mBuffers[b].mDataByteSize   = MA_MAX_SLICE * sizeof(float);
        s->inList->mBuffers[b].mData           = calloc(MA_MAX_SLICE, sizeof(float));
        if (!s->inList->mBuffers[b].mData) IFAIL("Out of memory.");
    }
    s->ilv = (float *)calloc(MA_MAX_SLICE * 2, sizeof(float));
    if (!s->ilv) IFAIL("Out of memory.");
    if (!rb_init(&s->ring, MA_RING_FRAMES)) IFAIL("Out of memory.");

    s->gateEnv = 0.0f; s->gateGain = 1.0f;
    atomic_store_explicit(&s->active, 1, memory_order_release);

    // Every already-running bus becomes a consumer of this new input.
    for (int b = 0; b < MA_MAX_OUTPUTS; b++) {
        if (atomic_load_explicit(&e->out[b].active, memory_order_acquire)) {
            rb_attach(&s->ring, (uint32_t)b);
            e->out[b].phase[slot] = 0.0;
        }
    }
    recompute_solo(e);
    ICHK(AudioOutputUnitStart(s->unit), "Starting capture failed");
    return 0;
}

void macamp_clear_output(MacAmpEngine *e, int bus) {
    if (!e || bus < 0 || bus >= MA_MAX_OUTPUTS) return;
    OutputBus *o = &e->out[bus];
    atomic_store_explicit(&o->active, 0, memory_order_release);

    // Detach first so the producers stop pacing to a cursor that is going away.
    for (int i = 0; i < MA_MAX_INPUTS; i++)
        if (e->in[i].ring.data) rb_detach(&e->in[i].ring, (uint32_t)bus);

    if (o->unit) {
        AudioOutputUnitStop(o->unit);
        AudioUnitUninitialize(o->unit);
        AudioComponentInstanceDispose(o->unit);
        o->unit = NULL;
    }
    o->dev = 0; o->rate = 0; o->channels = 0;
}

#define OFAIL(fmt, ...) do { snprintf(err, errLen, fmt, ##__VA_ARGS__); \
                             macamp_clear_output(e, bus); return -1; } while (0)
#define OCHK(call, fmt, ...) do { OSStatus _s = (call); if (_s != noErr) { \
        snprintf(err, errLen, fmt " (OSStatus %d)", ##__VA_ARGS__, (int)_s); \
        macamp_clear_output(e, bus); return (int)_s; } } while (0)

int macamp_set_output(MacAmpEngine *e, int bus, AudioDeviceID dev, char *err, size_t errLen) {
    if (!e || bus < 0 || bus >= MA_MAX_OUTPUTS) return -1;
    macamp_clear_output(e, bus);
    err[0] = '\0';
    OutputBus *o = &e->out[bus];

    UInt32 ch = device_channels(dev, 0);
    if (!ch) OFAIL("That device reports no output channels.");
    o->channels = ch < 2 ? 2 : ch;

    try_set_buffer_size(dev, MA_BUFFER_FRAMES);
    o->rate = device_rate(dev);
    if (o->rate <= 0) OFAIL("Could not read the output device's sample rate.");
    o->dev = dev;

    UInt32 enable = 1, disable = 0, maxSlice = MA_MAX_SLICE;
    o->unit = new_halunit();
    if (!o->unit) OFAIL("Could not instantiate an output audio unit.");

    OCHK(AudioUnitSetProperty(o->unit, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output, 0, &enable, sizeof enable), "Enabling playback failed");
    OCHK(AudioUnitSetProperty(o->unit, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1, &disable, sizeof disable), "Disabling capture failed");
    OCHK(AudioUnitSetProperty(o->unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &dev, sizeof dev), "Binding the output device failed");

    AudioStreamBasicDescription f = pcm_format(o->rate, o->channels);
    OCHK(AudioUnitSetProperty(o->unit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0, &f, sizeof f), "Device rejected float playback format");
    OCHK(AudioUnitSetProperty(o->unit, kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global, 0, &maxSlice, sizeof maxSlice), "Setting slice size failed");

    AURenderCallbackStruct cb = { outputProc, o };
    OCHK(AudioUnitSetProperty(o->unit, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0, &cb, sizeof cb), "Installing the render callback failed");
    OCHK(AudioUnitInitialize(o->unit), "Initializing the output unit failed");

    atomic_store_explicit(&o->underruns, 0, memory_order_relaxed);
    atomic_store_explicit(&o->active, 1, memory_order_release);

    for (int i = 0; i < MA_MAX_INPUTS; i++) {
        if (atomic_load_explicit(&e->in[i].active, memory_order_acquire)) {
            rb_attach(&e->in[i].ring, (uint32_t)bus);
            o->phase[i] = 0.0;
        }
    }
    OCHK(AudioOutputUnitStart(o->unit), "Starting playback failed");
    return 0;
}

void macamp_destroy(MacAmpEngine *e) {
    if (!e) return;
    for (int b = 0; b < MA_MAX_OUTPUTS; b++) macamp_clear_output(e, b);
    for (int i = 0; i < MA_MAX_INPUTS;  i++) macamp_clear_input(e, i);
    free(e);
}

int macamp_input_active(const MacAmpEngine *e, int slot) {
    if (!e || slot < 0 || slot >= MA_MAX_INPUTS) return 0;
    return atomic_load_explicit(&e->in[slot].active, memory_order_relaxed);
}
int macamp_output_active(const MacAmpEngine *e, int bus) {
    if (!e || bus < 0 || bus >= MA_MAX_OUTPUTS) return 0;
    return atomic_load_explicit(&e->out[bus].active, memory_order_relaxed);
}

// ---------------------------------------------------------------------------
// Routing and controls
// ---------------------------------------------------------------------------
void macamp_set_route(MacAmpEngine *e, int slot, int bus, int on) {
    if (!e || slot < 0 || slot >= MA_MAX_INPUTS || bus < 0 || bus >= MA_MAX_OUTPUTS) return;
    uint32_t m = 1u << route_bit(slot, bus);
    if (on) atomic_fetch_or_explicit (&e->routes,  m, memory_order_relaxed);
    else    atomic_fetch_and_explicit(&e->routes, ~m, memory_order_relaxed);
}
int macamp_get_route(const MacAmpEngine *e, int slot, int bus) {
    if (!e || slot < 0 || slot >= MA_MAX_INPUTS || bus < 0 || bus >= MA_MAX_OUTPUTS) return 0;
    return routed(e, slot, bus);
}

#define GUARD(x) if (!e || slot < 0 || slot >= MA_MAX_INPUTS) return x

void macamp_set_gain(MacAmpEngine *e, int slot, float v) { GUARD(); if (v < 0) v = 0; stf(&e->in[slot].gain, v); }
void macamp_set_pan (MacAmpEngine *e, int slot, float v) { GUARD(); stf(&e->in[slot].pan, v); }
void macamp_set_mute(MacAmpEngine *e, int slot, int on)  { GUARD(); atomic_store_explicit(&e->in[slot].mute, on ? 1 : 0, memory_order_relaxed); }
void macamp_set_solo(MacAmpEngine *e, int slot, int on)  { GUARD(); atomic_store_explicit(&e->in[slot].solo, on ? 1 : 0, memory_order_relaxed); recompute_solo(e); }
void macamp_set_gate(MacAmpEngine *e, int slot, int on, float db) {
    GUARD();
    atomic_store_explicit(&e->in[slot].gateOn, on ? 1 : 0, memory_order_relaxed);
    stf(&e->in[slot].gateThresh, db);
}

float macamp_get_gain(const MacAmpEngine *e, int slot) { GUARD(0.0f); return ldf(&e->in[slot].gain); }
float macamp_get_pan (const MacAmpEngine *e, int slot) { GUARD(0.0f); return ldf(&e->in[slot].pan); }
int   macamp_get_mute(const MacAmpEngine *e, int slot) { GUARD(0); return atomic_load_explicit(&e->in[slot].mute, memory_order_relaxed); }
int   macamp_get_solo(const MacAmpEngine *e, int slot) { GUARD(0); return atomic_load_explicit(&e->in[slot].solo, memory_order_relaxed); }
int   macamp_get_gate(const MacAmpEngine *e, int slot) { GUARD(0); return atomic_load_explicit(&e->in[slot].gateOn, memory_order_relaxed); }
float macamp_get_gate_threshold(const MacAmpEngine *e, int slot) { GUARD(-50.0f); return ldf(&e->in[slot].gateThresh); }
int   macamp_gate_open(const MacAmpEngine *e, int slot) { GUARD(1); return atomic_load_explicit(&e->in[slot].gateOpen, memory_order_relaxed); }

void macamp_read_peaks(MacAmpEngine *e, int slot, float *l, float *r) {
    if (!e || slot < 0 || slot >= MA_MAX_INPUTS) { if (l) *l = 0; if (r) *r = 0; return; }
    if (l) *l = ldf(&e->in[slot].peakL);
    if (r) *r = ldf(&e->in[slot].peakR);
    stf(&e->in[slot].peakL, 0.0f);   // clear-on-read: the UI owns the decay
    stf(&e->in[slot].peakR, 0.0f);
}

double macamp_input_rate(const MacAmpEngine *e, int slot) { GUARD(0.0); return e->in[slot].rate; }

double macamp_output_rate(const MacAmpEngine *e, int bus) {
    if (!e || bus < 0 || bus >= MA_MAX_OUTPUTS) return 0.0;
    return e->out[bus].rate;
}
uint32_t macamp_underruns(const MacAmpEngine *e, int bus) {
    if (!e || bus < 0 || bus >= MA_MAX_OUTPUTS) return 0;
    return atomic_load_explicit(&e->out[bus].underruns, memory_order_relaxed);
}
double macamp_latency_ms(const MacAmpEngine *e, int bus) {
    if (!e || bus < 0 || bus >= MA_MAX_OUTPUTS) return 0.0;
    const OutputBus *o = &e->out[bus];
    if (o->rate <= 0) return 0.0;
    uint32_t fill = atomic_load_explicit(&o->fill, memory_order_relaxed);
    double ringMs = (double)fill * 1000.0 / o->rate;
    return ringMs + (double)MA_BUFFER_FRAMES * 2000.0 / o->rate;
}
