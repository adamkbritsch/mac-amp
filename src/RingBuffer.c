#include "RingBuffer.h"
#include <stdlib.h>
#include <string.h>

static uint32_t next_pow2(uint32_t v) {
    if (v < 2) return 2;
    v--; v |= v>>1; v |= v>>2; v |= v>>4; v |= v>>8; v |= v>>16;
    return v + 1;
}

int rb_init(RingBuffer *rb, uint32_t capacityFrames) {
    uint32_t cap = next_pow2(capacityFrames);
    rb->data = (float *)calloc((size_t)cap * 2, sizeof(float));
    if (!rb->data) return 0;
    rb->capacity = cap;
    rb->mask     = cap - 1;
    atomic_store_explicit(&rb->write, 0, memory_order_relaxed);
    for (uint32_t i = 0; i < MA_MAX_CONSUMERS; i++)
        atomic_store_explicit(&rb->read[i], 0, memory_order_relaxed);
    atomic_store_explicit(&rb->active, 0, memory_order_relaxed);
    return 1;
}

void rb_free(RingBuffer *rb) {
    free(rb->data);
    rb->data = NULL;
    rb->capacity = rb->mask = 0;
    atomic_store_explicit(&rb->active, 0, memory_order_relaxed);
}

void rb_attach(RingBuffer *rb, uint32_t c) {
    if (c >= MA_MAX_CONSUMERS) return;
    uint32_t w = atomic_load_explicit(&rb->write, memory_order_acquire);
    atomic_store_explicit(&rb->read[c], w, memory_order_release);
    atomic_fetch_or_explicit(&rb->active, 1u << c, memory_order_release);
}

void rb_detach(RingBuffer *rb, uint32_t c) {
    if (c >= MA_MAX_CONSUMERS) return;
    // Clear the bit first so the producer stops waiting on this cursor.
    atomic_fetch_and_explicit(&rb->active, ~(1u << c), memory_order_release);
}

int rb_is_attached(const RingBuffer *rb, uint32_t c) {
    if (c >= MA_MAX_CONSUMERS) return 0;
    return (atomic_load_explicit(&rb->active, memory_order_acquire) >> c) & 1u;
}

uint32_t rb_available(const RingBuffer *rb, uint32_t c) {
    if (c >= MA_MAX_CONSUMERS) return 0;
    uint32_t w = atomic_load_explicit(&rb->write,    memory_order_acquire);
    uint32_t r = atomic_load_explicit(&rb->read[c],  memory_order_relaxed);
    return w - r;
}

uint32_t rb_space(const RingBuffer *rb) {
    uint32_t w   = atomic_load_explicit(&rb->write,  memory_order_relaxed);
    uint32_t act = atomic_load_explicit(&rb->active, memory_order_acquire);
    uint32_t used = 0;
    for (uint32_t c = 0; c < MA_MAX_CONSUMERS; c++) {
        if (!((act >> c) & 1u)) continue;
        uint32_t u = w - atomic_load_explicit(&rb->read[c], memory_order_acquire);
        if (u > used) used = u;
    }
    return rb->capacity - used;
}

uint32_t rb_write(RingBuffer *rb, const float *src, uint32_t frames) {
    uint32_t w    = atomic_load_explicit(&rb->write,  memory_order_relaxed);
    uint32_t act  = atomic_load_explicit(&rb->active, memory_order_acquire);

    // With no consumer attached the ring is a sink: keep the head moving so
    // late joiners see fresh audio, but never block on a cursor nobody owns.
    uint32_t used = 0;
    for (uint32_t c = 0; c < MA_MAX_CONSUMERS; c++) {
        if (!((act >> c) & 1u)) continue;
        uint32_t r = atomic_load_explicit(&rb->read[c], memory_order_acquire);
        uint32_t u = w - r;                 // unsigned: correct across wrap
        if (u > used) used = u;             // pace to the FURTHEST BEHIND
    }

    uint32_t space = rb->capacity - used;
    uint32_t n     = frames < space ? frames : space;

    for (uint32_t i = 0; i < n; i++) {
        uint32_t idx = (w + i) & rb->mask;
        rb->data[idx * 2 + 0] = src[i * 2 + 0];
        rb->data[idx * 2 + 1] = src[i * 2 + 1];
    }
    atomic_store_explicit(&rb->write, w + n, memory_order_release);
    return n;
}

int rb_peek_frame(const RingBuffer *rb, uint32_t c,
                  uint32_t frameOffset, float *outL, float *outR) {
    if (c >= MA_MAX_CONSUMERS) return 0;
    uint32_t r = atomic_load_explicit(&rb->read[c], memory_order_relaxed);
    uint32_t w = atomic_load_explicit(&rb->write,   memory_order_acquire);
    if (frameOffset >= (w - r)) return 0;
    uint32_t idx = (r + frameOffset) & rb->mask;
    *outL = rb->data[idx * 2 + 0];
    *outR = rb->data[idx * 2 + 1];
    return 1;
}

void rb_advance(RingBuffer *rb, uint32_t c, uint32_t frames) {
    if (c >= MA_MAX_CONSUMERS) return;
    uint32_t r = atomic_load_explicit(&rb->read[c], memory_order_relaxed);
    atomic_store_explicit(&rb->read[c], r + frames, memory_order_release);
}
