// RingBuffer.h -- lock-free single-producer/single-consumer ring buffer.
//
// Producer = CoreAudio input render thread. Consumer = CoreAudio output render
// thread. Two different realtime threads, so this must be lock-free and must
// not allocate. Samples are stored INTERLEAVED stereo float32.
#ifndef MACAMP_RINGBUFFER_H
#define MACAMP_RINGBUFFER_H

#include <stdatomic.h>
#include <stdint.h>
#include <stddef.h>

typedef struct {
    float          *data;      // capacity * 2 floats (interleaved stereo)
    uint32_t        capacity;  // in FRAMES, always a power of two
    uint32_t        mask;      // capacity - 1
    _Atomic uint32_t write;    // monotonic frame counter, wraps naturally
    _Atomic uint32_t read;     // monotonic frame counter, wraps naturally
} RingBuffer;

// capacityFrames is rounded up to a power of two. Returns 0 on failure.
int  rb_init(RingBuffer *rb, uint32_t capacityFrames);
void rb_free(RingBuffer *rb);
void rb_reset(RingBuffer *rb);

// Frames currently readable / writable. Safe to call from either thread.
uint32_t rb_available(const RingBuffer *rb);
uint32_t rb_space(const RingBuffer *rb);

// Producer side. Writes `frames` interleaved stereo frames. Returns frames
// actually written (short write means overrun).
uint32_t rb_write(RingBuffer *rb, const float *src, uint32_t frames);

// Consumer side. Peek does NOT advance the read pointer -- the fractional
// resampler needs to look ahead by up to 3 frames for cubic interpolation.
// frameOffset is relative to the current read position.
// Returns 1 if the frame was available, 0 otherwise.
int  rb_peek_frame(const RingBuffer *rb, uint32_t frameOffset, float *outL, float *outR);
void rb_advance(RingBuffer *rb, uint32_t frames);

#endif
