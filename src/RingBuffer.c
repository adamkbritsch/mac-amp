#include "RingBuffer.h"
#include <stdlib.h>
#include <string.h>

static uint32_t next_pow2(uint32_t v) {
    if (v < 2) return 2;
    v--;
    v |= v >> 1; v |= v >> 2; v |= v >> 4; v |= v >> 8; v |= v >> 16;
    return v + 1;
}

int rb_init(RingBuffer *rb, uint32_t capacityFrames) {
    uint32_t cap = next_pow2(capacityFrames);
    rb->data = (float *)calloc((size_t)cap * 2, sizeof(float));
    if (!rb->data) return 0;
    rb->capacity = cap;
    rb->mask     = cap - 1;
    atomic_store_explicit(&rb->write, 0, memory_order_relaxed);
    atomic_store_explicit(&rb->read,  0, memory_order_relaxed);
    return 1;
}

void rb_free(RingBuffer *rb) {
    free(rb->data);
    rb->data = NULL;
    rb->capacity = rb->mask = 0;
}

void rb_reset(RingBuffer *rb) {
    atomic_store_explicit(&rb->write, 0, memory_order_relaxed);
    atomic_store_explicit(&rb->read,  0, memory_order_relaxed);
    if (rb->data) memset(rb->data, 0, (size_t)rb->capacity * 2 * sizeof(float));
}

// Counters are monotonic and allowed to wrap; unsigned subtraction stays
// correct across the wrap, which is why we never mask the counters themselves.
uint32_t rb_available(const RingBuffer *rb) {
    uint32_t w = atomic_load_explicit(&rb->write, memory_order_acquire);
    uint32_t r = atomic_load_explicit(&rb->read,  memory_order_acquire);
    return w - r;
}

uint32_t rb_space(const RingBuffer *rb) {
    return rb->capacity - rb_available(rb);
}

uint32_t rb_write(RingBuffer *rb, const float *src, uint32_t frames) {
    // Producer owns `write`, so it may read it relaxed. `read` is written by
    // the consumer, so acquire pairs with the consumer's release in rb_advance.
    uint32_t w = atomic_load_explicit(&rb->write, memory_order_relaxed);
    uint32_t r = atomic_load_explicit(&rb->read,  memory_order_acquire);

    uint32_t used  = w - r;
    uint32_t space = rb->capacity - used;
    uint32_t n     = frames < space ? frames : space;

    for (uint32_t i = 0; i < n; i++) {
        uint32_t idx = (w + i) & rb->mask;
        rb->data[idx * 2 + 0] = src[i * 2 + 0];
        rb->data[idx * 2 + 1] = src[i * 2 + 1];
    }

    // Release: the sample writes above must be visible before the consumer
    // sees the advanced write counter.
    atomic_store_explicit(&rb->write, w + n, memory_order_release);
    return n;
}

int rb_peek_frame(const RingBuffer *rb, uint32_t frameOffset, float *outL, float *outR) {
    uint32_t r = atomic_load_explicit(&rb->read,  memory_order_relaxed);
    uint32_t w = atomic_load_explicit(&rb->write, memory_order_acquire);
    if (frameOffset >= (w - r)) return 0;
    uint32_t idx = (r + frameOffset) & rb->mask;
    *outL = rb->data[idx * 2 + 0];
    *outR = rb->data[idx * 2 + 1];
    return 1;
}

void rb_advance(RingBuffer *rb, uint32_t frames) {
    uint32_t r = atomic_load_explicit(&rb->read, memory_order_relaxed);
    atomic_store_explicit(&rb->read, r + frames, memory_order_release);
}
