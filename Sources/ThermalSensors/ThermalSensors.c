#include "ThermalSensors.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdint.h>

// Resolve optional HID temperature APIs at runtime so unsupported systems
// return no readings instead of preventing the application from launching.
void PVReadTemperatureSensors(PVTemperatureHandler handler, void *context) {
    PVReadTemperatureSensorsMatching(NULL, handler, context);
}

void PVReadTemperatureSensorsMatching(PVTemperatureFilter wanted, PVTemperatureHandler handler, void *context) {
    if (!handler) return;
    void *library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
    if (!library) return;
    CFTypeRef (*create)(CFAllocatorRef) = dlsym(library, "IOHIDEventSystemClientCreate");
    void (*setMatching)(CFTypeRef, CFDictionaryRef) = dlsym(library, "IOHIDEventSystemClientSetMatching");
    CFArrayRef (*copyServices)(CFTypeRef) = dlsym(library, "IOHIDEventSystemClientCopyServices");
    CFTypeRef (*copyProperty)(CFTypeRef, CFStringRef) = dlsym(library, "IOHIDServiceClientCopyProperty");
    CFTypeRef (*copyEvent)(CFTypeRef, int64_t, int32_t, int64_t) = dlsym(library, "IOHIDServiceClientCopyEvent");
    double (*floatValue)(CFTypeRef, int32_t) = dlsym(library, "IOHIDEventGetFloatValue");
    if (!create || !setMatching || !copyServices || !copyProperty || !copyEvent || !floatValue) {
        dlclose(library);
        return;
    }
    CFTypeRef client = create(kCFAllocatorDefault);
    if (!client) { dlclose(library); return; }
    int page = 0xff00, usage = 5;
    CFNumberRef pageValue = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef usageValue = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *values[] = { pageValue, usageValue };
    CFDictionaryRef filter = CFDictionaryCreate(NULL, keys, values, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    setMatching(client, filter);
    CFArrayRef services = copyServices(client);
    if (services) {
        for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
            CFTypeRef service = CFArrayGetValueAtIndex(services, i);
            CFTypeRef name = copyProperty(service, CFSTR("Product"));
            char label[256];
            if (name && CFGetTypeID(name) == CFStringGetTypeID()
                && CFStringGetCString(name, label, sizeof(label), kCFStringEncodingUTF8)
                && (!wanted || wanted(label))) {
                CFTypeRef event = copyEvent(service, 15, 0, 0);
                if (event) {
                    handler(label, floatValue(event, 15 << 16), context);
                    CFRelease(event);
                }
            }
            if (name) CFRelease(name);
        }
        CFRelease(services);
    }
    CFRelease(filter);
    CFRelease(pageValue);
    CFRelease(usageValue);
    CFRelease(client);
    dlclose(library);
}
