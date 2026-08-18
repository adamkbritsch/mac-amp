// RingBuffer.h -- lock-free ring, one producer, up to MA_MAX_CONSUMERS readers.
//
// Producer = one CoreAudio input render thread. Consumers = the output bus
// threads that this input is routed to. Each consumer holds its own read
// cursor and its own fractional resample phase, so the same captured audio can
// feed several buses running at different rates off different clocks.
//
// The producer must respect the SLOWEST consumer: space is computed against
// the furthest-behind cursor, otherwise a bus that is momentarily starved
// would have samples overwritten underneath it.
//
// Samples are stored INTERLEAVED stereo float32.
#ifndef MACAMP_RINGBUFFER_H
#define MACAMP_RINGBUFFER_H

#include <stdatomic.h>
#include <stdint.h>
#include <stddef.h>

#define MA_MAX_CONSUMERS 4

typedef struct {
    float           *data;
    uint32_t         capacity;   // FRAMES, power of two
    uint32_t         mask;
    _Atomic uint32_t write;
    _Atomic uint32_t read[MA_MAX_CONSUMERS];
    _Atomic uint32_t active;     // bitmask of attached consumers
} RingBuffer;

int  rb_init(RingBuffer *rb, uint32_t capacityFrames);
void rb_free(RingBuffer *rb);

// Attaching parks the new cursor at the current write head, so a bus that
// joins mid-stream starts from "now" rather than replaying stale audio.
void rb_attach(RingBuffer *rb, uint32_t consumer);
void rb_detach(RingBuffer *rb, uint32_t consumer);
int  rb_is_attached(const RingBuffer *rb, uint32_t consumer);

uint32_t rb_available(const RingBuffer *rb, uint32_t consumer);
uint32_t rb_write(RingBuffer *rb, const float *src, uint32_t frames);

int  rb_peek_frame(const RingBuffer *rb, uint32_t consumer,
                   uint32_t frameOffset, float *outL, float *outR);
void rb_advance(RingBuffer *rb, uint32_t consumer, uint32_t frames);

#endif
