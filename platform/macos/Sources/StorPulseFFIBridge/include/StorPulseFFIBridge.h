#ifndef STORPULSE_FFI_BRIDGE_H
#define STORPULSE_FFI_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

typedef struct SpBridge SpBridge;

typedef struct {
    uint8_t *ptr;
    size_t len;
    int32_t status;
} SpBridgeBuffer;

SpBridge *sp_bridge_open(const char *library_path, char **error_message);
void sp_bridge_close(SpBridge *bridge);

int32_t sp_bridge_ingest(
    SpBridge *bridge,
    const uint8_t *json,
    size_t length
);

SpBridgeBuffer sp_bridge_snapshot(
    SpBridge *bridge,
    uint64_t monotonic_nanoseconds
);

SpBridgeBuffer sp_bridge_command(
    SpBridge *bridge,
    const uint8_t *json,
    size_t length
);

SpBridgeBuffer sp_bridge_last_error(SpBridge *bridge);
void sp_bridge_buffer_free(SpBridgeBuffer buffer);
void sp_bridge_string_free(char *message);

#endif
