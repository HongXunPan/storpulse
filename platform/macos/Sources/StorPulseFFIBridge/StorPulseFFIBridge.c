#include "StorPulseFFIBridge.h"

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint8_t *ptr;
    size_t len;
    size_t capacity;
    int32_t status;
} SpBuffer;

typedef void *(*EngineCreateFunction)(void);
typedef void (*EngineDestroyFunction)(void *engine);
typedef int32_t (*EngineIngestFunction)(
    void *engine,
    const uint8_t *json,
    size_t length
);
typedef SpBuffer (*EngineSnapshotFunction)(
    void *engine,
    uint64_t monotonic_nanoseconds
);
typedef SpBuffer (*EngineCommandFunction)(
    void *engine,
    const uint8_t *json,
    size_t length
);
typedef SpBuffer (*EngineLastErrorFunction)(void *engine);
typedef void (*BufferFreeFunction)(SpBuffer buffer);

struct SpBridge {
    void *library;
    void *engine;
    EngineDestroyFunction destroy;
    EngineIngestFunction ingest;
    EngineSnapshotFunction snapshot;
    EngineCommandFunction command;
    EngineLastErrorFunction last_error;
    BufferFreeFunction buffer_free;
};

static char *copy_string(const char *message) {
    if (message == NULL) {
        return NULL;
    }
    size_t length = strlen(message) + 1;
    char *copy = malloc(length);
    if (copy != NULL) {
        memcpy(copy, message, length);
    }
    return copy;
}

static void *load_symbol(void *library, const char *name, char **error_message) {
    dlerror();
    void *symbol = dlsym(library, name);
    const char *error = dlerror();
    if (error != NULL && error_message != NULL) {
        *error_message = copy_string(error);
    }
    return symbol;
}

SpBridge *sp_bridge_open(const char *library_path, char **error_message) {
    if (library_path == NULL) {
        if (error_message != NULL) {
            *error_message = copy_string("未提供 Rust 引擎动态库路径");
        }
        return NULL;
    }

    void *library = dlopen(library_path, RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) {
        if (error_message != NULL) {
            *error_message = copy_string(dlerror());
        }
        return NULL;
    }

    SpBridge *bridge = calloc(1, sizeof(SpBridge));
    if (bridge == NULL) {
        dlclose(library);
        return NULL;
    }
    bridge->library = library;

#define LOAD_SYMBOL(field, type, name)                                      \
    do {                                                                    \
        bridge->field = (type)load_symbol(library, name, error_message);     \
        if (bridge->field == NULL) {                                        \
            sp_bridge_close(bridge);                                        \
            return NULL;                                                    \
        }                                                                   \
    } while (0)

    EngineCreateFunction create;
    LOAD_SYMBOL(destroy, EngineDestroyFunction, "sp_engine_destroy");
    LOAD_SYMBOL(ingest, EngineIngestFunction, "sp_engine_ingest_json");
    LOAD_SYMBOL(snapshot, EngineSnapshotFunction, "sp_engine_snapshot_json");
    LOAD_SYMBOL(command, EngineCommandFunction, "sp_engine_command_json");
    LOAD_SYMBOL(last_error, EngineLastErrorFunction, "sp_engine_last_error_json");
    LOAD_SYMBOL(buffer_free, BufferFreeFunction, "sp_buffer_free");
    create = (EngineCreateFunction)load_symbol(library, "sp_engine_create", error_message);
    if (create == NULL) {
        sp_bridge_close(bridge);
        return NULL;
    }
#undef LOAD_SYMBOL

    bridge->engine = create();
    if (bridge->engine == NULL) {
        sp_bridge_close(bridge);
        return NULL;
    }
    return bridge;
}

void sp_bridge_close(SpBridge *bridge) {
    if (bridge == NULL) {
        return;
    }
    if (bridge->engine != NULL && bridge->destroy != NULL) {
        bridge->destroy(bridge->engine);
    }
    if (bridge->library != NULL) {
        dlclose(bridge->library);
    }
    free(bridge);
}

int32_t sp_bridge_ingest(SpBridge *bridge, const uint8_t *json, size_t length) {
    if (bridge == NULL || bridge->engine == NULL) {
        return 1;
    }
    return bridge->ingest(bridge->engine, json, length);
}

static SpBridgeBuffer copy_buffer(SpBridge *bridge, SpBuffer source) {
    SpBridgeBuffer result = {NULL, 0, source.status};
    if (source.ptr != NULL && source.len > 0) {
        result.ptr = malloc(source.len);
        if (result.ptr == NULL) {
            result.status = 4;
        } else {
            memcpy(result.ptr, source.ptr, source.len);
            result.len = source.len;
        }
    }
    if (bridge != NULL && bridge->buffer_free != NULL) {
        bridge->buffer_free(source);
    }
    return result;
}

SpBridgeBuffer sp_bridge_snapshot(SpBridge *bridge, uint64_t monotonic_nanoseconds) {
    if (bridge == NULL || bridge->engine == NULL) {
        SpBridgeBuffer result = {NULL, 0, 1};
        return result;
    }
    return copy_buffer(
        bridge,
        bridge->snapshot(bridge->engine, monotonic_nanoseconds)
    );
}

SpBridgeBuffer sp_bridge_command(SpBridge *bridge, const uint8_t *json, size_t length) {
    if (bridge == NULL || bridge->engine == NULL) {
        SpBridgeBuffer result = {NULL, 0, 1};
        return result;
    }
    return copy_buffer(bridge, bridge->command(bridge->engine, json, length));
}

SpBridgeBuffer sp_bridge_last_error(SpBridge *bridge) {
    if (bridge == NULL || bridge->engine == NULL) {
        SpBridgeBuffer result = {NULL, 0, 1};
        return result;
    }
    return copy_buffer(bridge, bridge->last_error(bridge->engine));
}

void sp_bridge_buffer_free(SpBridgeBuffer buffer) {
    free(buffer.ptr);
}

void sp_bridge_string_free(char *message) {
    free(message);
}
