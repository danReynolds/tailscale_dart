#ifndef DART_PUSH_H
#define DART_PUSH_H

#include "dart/dart_api_dl.h"

// Initialize the Dart DL API. Must be called once with NativeApi.initializeApiDLData.
intptr_t dart_push_init(void* data);

// Post a UTF-8 string to the specified Dart port.
// Returns true on success. Thread-safe.
bool dart_push_string(Dart_Port_DL port, const char* message);

#endif
