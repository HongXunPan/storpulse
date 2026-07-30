#ifndef STORPULSE_H
#define STORPULSE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
typedef struct SpEngine SpEngine;

typedef struct SpBuffer {
    uint8_t *ptr;
    size_t len;
    size_t capacity;
    int32_t status;
} SpBuffer;

enum {
    SP_STATUS_OK = 0,
    SP_STATUS_INVALID_HANDLE = 1,
    SP_STATUS_INVALID_INPUT = 2,
    SP_STATUS_ENGINE_ERROR = 3,
    SP_STATUS_INTERNAL_ERROR = 4
};

SpEngine *sp_engine_create(void);
void sp_engine_destroy(SpEngine *engine);

int32_t sp_engine_ingest_json(
    SpEngine *engine,
    const uint8_t *json,
    size_t length
);

SpBuffer sp_engine_snapshot_json(
    SpEngine *engine,
    uint64_t monotonic_nanoseconds
);

SpBuffer sp_engine_command_json(
    SpEngine *engine,
    const uint8_t *json,
    size_t length
);

SpBuffer sp_engine_last_error_json(SpEngine *engine);
void sp_buffer_free(SpBuffer buffer);

#ifdef __cplusplus
}
#endif

#endif
