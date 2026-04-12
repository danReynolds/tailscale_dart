#include "dart_push.h"
#include <string.h>

intptr_t dart_push_init(void* data) {
    return Dart_InitializeApiDL(data);
}

bool dart_push_string(Dart_Port_DL port, const char* message) {
    if (Dart_PostCObject_DL == NULL) return false;

    Dart_CObject obj;
    obj.type = Dart_CObject_kString;
    obj.value.as_string = (char*)message;

    return Dart_PostCObject_DL(port, &obj);
}
