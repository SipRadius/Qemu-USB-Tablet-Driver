/*
 * Copyright (c) 2013 Alexander Tarasikov
 * Copyright (c) 2014 Rafaël Carré
 * Copyright (c) 2014 SipRadius LLC
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOMessage.h>
#include <IOKit/hidsystem/event_status_driver.h>

#include <ApplicationServices/ApplicationServices.h>
#include <Foundation/Foundation.h>

#include <stdint.h>
#include <sys/time.h>

#include "HidUtils.h"

//---------------------------------------------------------------------------
// Globals
//---------------------------------------------------------------------------
static IONotificationPortRef gNotifyPort;
static NSLock *gLock;

static void Wheel(int wheel)
{
    static int eventNumber = 0;
    CGEventRef w = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 1, wheel);
    CGEventSetIntegerValueField(w, kCGMouseEventNumber, eventNumber);
    CGEventPost(kCGHIDEventTap, w);
    CFRelease(w);

#ifdef DEBUG
    printf("%s: %d\n", __func__, wheel);
#endif

    eventNumber++;
}

static void Click(int button, int x, int y, ButtonState state)
{
    static int eventNumber[3];
    static uint64_t last_click[3];
    static bool button_pressed[3];

    static const CGEventType type[3][2] = {
        { [DOWN] = kCGEventLeftMouseDown,
          [UP]   = kCGEventLeftMouseUp, },
        { [DOWN] = kCGEventRightMouseDown,
          [UP]   = kCGEventRightMouseUp, },
        { [DOWN] = kCGEventOtherMouseDown,
          [UP]   = kCGEventOtherMouseUp, },
    };

    static const int mouse_drag_events[3] = {
        kCGEventLeftMouseDragged,
        kCGEventRightMouseDragged,
        kCGEventOtherMouseDragged
    };

    CGEventRef move = CGEventCreateMouseEvent(NULL,
            (state == NO_CHANGE) ? ( button_pressed[button] ? mouse_drag_events[button] : kCGEventMouseMoved ) : type[button][state],
            CGPointMake(x, y), button);
    CGEventSetIntegerValueField(move, kCGMouseEventNumber, eventNumber[button]);
    if (state == UP) {
        NXEventHandle handle = NXOpenEventStatus();
        double clickTime = NXClickTime(handle);
        NXCloseEventStatus(handle);
        struct timeval tv;
        gettimeofday(&tv, NULL);
        uint64_t now = tv.tv_sec * 1000000 + tv.tv_usec;

        if (now - last_click[button] < 1000000 * clickTime)
            CGEventSetIntegerValueField(move, kCGMouseEventClickState, 2);
        last_click[button] = now;
        button_pressed[button] = false;
    }
    else if (state == DOWN) {
        button_pressed[button] = true;
    }

    CGEventPost(kCGHIDEventTap, move);
    CFRelease(move);

    if (state == UP)
        eventNumber[button]++;
}

static void Touch(int button, int x, int y, ButtonState state)
{
    static int last_x, last_y;

    if (x >= 0)
        last_x = x;
    if (y >= 0)
        last_y = y;

#ifdef DEBUG
    static const char *btn[] = {
        [DOWN]      = "DOWN",
        [UP]        = "UP",
        [NO_CHANGE] = "xy",
    };

    printf("%s: <%dx%d> %s - button %d\n", __func__,
        last_x, last_y, btn[state], button);
#endif

    Click(button, last_x, last_y, state);
}

#ifdef DEBUG
static const char *translateHIDType(IOHIDElementType type)
{
    switch (type) {
    case 1:   return "MISC";
    case 2:   return "Button";
    case 3:   return "Axis";
    case 4:   return "ScanCodes";
    case 129: return "Output";
    case 257: return "Feature";
    case 513: return "Collection";
    default:  return "unknown";
    }
};
#endif

static void printHidElement(const char *fname, HIDElement *e)
{
#ifdef DEBUG
    if (!e)
        return;

    const char *hidUsage = "unknown";

    SInt32 u = e->usage;

    if (e->usagePage == 1) {
        switch(u) {
        case 0x01: hidUsage = "Pointer"; break;
        case 0x30: hidUsage = "X"; break;
        case 0x31: hidUsage = "Y"; break;
        case 0x38: hidUsage = "Wheel"; break;
        }
    } else if (e->usagePage == 0x9) {
        switch(u) {
        case 0x01: hidUsage = "Button 1"; break;
        case 0x02: hidUsage = "Button 2"; break;
        case 0x03: hidUsage = "Button 3"; break;
        }
    } else if (e->usagePage == 0xd) {
        switch(u) {
        case kHIDUsage_Dig_TouchScreen: hidUsage = "Touchscreen"; break;
        case 0x1: hidUsage = "Digitizer"; break;
        case 2: hidUsage = "Pen"; break;
        case 0x3: hidUsage = "Config"; break;
        case 0x20: hidUsage = "stylus"; break;
        case 0x22: hidUsage = "finger"; break;
        case 0x23: hidUsage = "DevSettings"; break;
        case 0x30: hidUsage = "pressure"; break;
        case 0x32: hidUsage = "InRange"; break;
        case kHIDUsage_Dig_Touch: hidUsage = "Touch"; break;
        case 0x3c: hidUsage = "Invert"; break;
        case 0x3f: hidUsage = "Azimuth"; break;
        case 0x42: hidUsage = "TipSwitch"; break;
        case 0x47: hidUsage = "Confidence"; break;
        case 0x48: hidUsage = "MT Widght"; break;
        case 0x49: hidUsage = "MT Height"; break;
        case 0x51: hidUsage = "ContactID"; break;
        case 0x53: hidUsage = "DevIndex"; break;
        case 0x54: hidUsage = "TouchCount"; break;
        case 0x55: hidUsage = "Contact Count Maximum"; break;
        case 0x56: hidUsage = "ScanTime"; break;
        }
    }

    printf("[%s]: <%x:%x> [%s] %s=0x%d\n",
           fname,
           e->usagePage, e->usage,
           translateHIDType(e->type),
           hidUsage,
           e->currentValue);
#else
    (void)fname; (void)e;
#endif
}

static bool acceptHidElement(HIDElement *e)
{
    printHidElement("acceptHidElement", e);
    SInt32 u = e->usage;

    switch (e->usagePage) {
    case kHIDPage_GenericDesktop: return u == kHIDUsage_GD_X || u == kHIDUsage_GD_Y || u == kHIDUsage_GD_Wheel;
    case kHIDPage_Button:         return u == kHIDUsage_Button_1 || u == kHIDUsage_Button_2 || u == kHIDUsage_Button_3;
    case kHIDPage_Digitizer:      return true;
    default: return false;
    }
}

static void reportHidElement(HIDElement *element)
{
    if (!element)
        return;

    [gLock lock];

    //printHidElement("report element", element);

    if (element->type == kIOHIDElementTypeInput_Button)
        Touch(element->usage - kHIDUsage_Button_1, -1, -1, element->currentValue ? DOWN : UP);

    SInt32 u = element->usage;

    if (element->usagePage == 1 && element->currentValue < 0x10000) {
        short value = element->currentValue & 0xffff;

        int x = -1, y = -1;

        if (u == kHIDUsage_GD_X)
            x = (int)(value * CGDisplayPixelsWide(CGMainDisplayID()) / 32768.0f);
        else if (u == kHIDUsage_GD_Y)
            y = (int)(value * CGDisplayPixelsHigh(CGMainDisplayID()) / 32768.0f);
        else if (u == kHIDUsage_GD_Wheel && value)
            Wheel(value);

        Touch(0, x, y, NO_CHANGE);
    }

    [gLock unlock];
}

//---------------------------------------------------------------------------
// QueueCallbackFunction
//---------------------------------------------------------------------------
static void QueueCallbackFunction(void *target, IOReturn result, void *refcon, void *sender)
{
    HIDDataRef hidDataRef = (HIDDataRef)refcon;

    if (!hidDataRef)
        return;

    IOHIDQueueInterface **q = hidDataRef->hidQueueInterface;

    if (sender != q)
        return;

    while (result == kIOReturnSuccess) {
        IOHIDEventStruct event;
        AbsoluteTime zeroTime = {0,0};
        result = (*q)->getNextEvent( q, &event, zeroTime, 0);

        if (result != kIOReturnSuccess)
            continue;

        // Only intersted in 32 values right now
        if (event.longValueSize) {
            free(event.longValue);
            continue;
        }

        CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &event.elementCookie);
        if (!number)
            continue;
        CFMutableDataRef element = (CFMutableDataRef)CFDictionaryGetValue(hidDataRef->hidElementDictionary, number);
        CFRelease(number);

        if (!element)
            continue;

        HIDElementRef tempHIDElement = (HIDElement *)CFDataGetMutableBytePtr(element);
        if (!tempHIDElement)
            continue;

        //bool change = (tempHIDElement->currentValue != event.value);
        tempHIDElement->currentValue = event.value;

        reportHidElement(tempHIDElement);
    }

}

//---------------------------------------------------------------------------
// SetupQueue
//---------------------------------------------------------------------------
static bool SetupQueue(HIDDataRef hidDataRef)
{
    bool ret = false;

    if (!hidDataRef->hidElementDictionary)
        return false;

    CFIndex count = CFDictionaryGetCount(hidDataRef->hidElementDictionary);
    if (count <= 0)
        return false;

    CFStringRef *keys = (CFStringRef *)malloc(sizeof(CFStringRef) * count);
    CFMutableDataRef *elements = (CFMutableDataRef *)malloc(sizeof(CFMutableDataRef) * count);

    CFDictionaryGetKeysAndValues(hidDataRef->hidElementDictionary, (const void **)keys, (const void **)elements);

    hidDataRef->hidQueueInterface = (*hidDataRef->hidDeviceInterface)->allocQueue(hidDataRef->hidDeviceInterface);
    if (!hidDataRef->hidQueueInterface)
        goto SETUP_QUEUE_CLEANUP;

    if (kIOReturnSuccess != (*hidDataRef->hidQueueInterface)->create(hidDataRef->hidQueueInterface, 0, 8))
        goto SETUP_QUEUE_CLEANUP;

    bool cookieAdded = false;
    for (CFIndex i=0; i<count; i++) {
        if (!elements[i])
            continue;

        HIDElementRef tempHIDElement = (HIDElementRef)CFDataGetMutableBytePtr(elements[i]);
        if (!tempHIDElement)
            continue;

        printHidElement("SetupQueue", tempHIDElement);

        if ((tempHIDElement->type < kIOHIDElementTypeInput_Misc) || (tempHIDElement->type > kIOHIDElementTypeInput_ScanCodes))
            continue;

        if (kIOReturnSuccess == (*hidDataRef->hidQueueInterface)->addElement(hidDataRef->hidQueueInterface, tempHIDElement->cookie, 0))
            cookieAdded = true;
    }

    if (cookieAdded) {
        if (kIOReturnSuccess != (*hidDataRef->hidQueueInterface)->createAsyncEventSource(hidDataRef->hidQueueInterface, &hidDataRef->eventSource))
            goto SETUP_QUEUE_CLEANUP;

        if (kIOReturnSuccess != (*hidDataRef->hidQueueInterface)->setEventCallout(hidDataRef->hidQueueInterface, QueueCallbackFunction, NULL, hidDataRef))
            goto SETUP_QUEUE_CLEANUP;

        CFRunLoopAddSource(CFRunLoopGetCurrent(), hidDataRef->eventSource, kCFRunLoopDefaultMode);

        if (kIOReturnSuccess != (*hidDataRef->hidQueueInterface)->start(hidDataRef->hidQueueInterface))
            goto SETUP_QUEUE_CLEANUP;
    } else {
        IOHIDQueueInterface **q = hidDataRef->hidQueueInterface;
        (*(q))->stop((q));
        (*(q))->dispose((q));
        (*(q))->Release (q);
        hidDataRef->hidQueueInterface = NULL;
    }

    ret = true;

SETUP_QUEUE_CLEANUP:

    free(keys);
    free(elements);

    return ret;
}

//---------------------------------------------------------------------------
// FindHIDElements
//---------------------------------------------------------------------------
static bool FindHIDElements(HIDDataRef hidDataRef)
{
    if (!hidDataRef)
        return false;

    /* Create a mutable dictionary to hold HID elements. */
    CFMutableDictionaryRef hidElements = CFDictionaryCreateMutable(
                                            kCFAllocatorDefault,
                                            0,
                                            &kCFTypeDictionaryKeyCallBacks,
                                            &kCFTypeDictionaryValueCallBacks);
    if (!hidElements)
        return false;

    // Let's find the elements
    CFArrayRef elementArray = NULL;
    if (kIOReturnSuccess != (*hidDataRef->hidDeviceInterface)->copyMatchingElements(
                                                                  hidDataRef->hidDeviceInterface,
                                                                  NULL,
                                                                  &elementArray) || !elementArray)
        goto FIND_ELEMENT_CLEANUP;

    //CFShow(elementArray);

    /* Iterate through the elements and read their values. */
    for (unsigned i=0; i<CFArrayGetCount(elementArray); i++) {
        CFDictionaryRef element = (CFDictionaryRef) CFArrayGetValueAtIndex(elementArray, i);
        if (!element)
            continue;

        HIDElement newElement;
        bzero(&newElement, sizeof(HIDElement));

        newElement.owner = hidDataRef;

        /* Read the element's usage page (top level category describing the type of
         element---kHIDPage_GenericDesktop, for example) */
        CFNumberRef number = (CFNumberRef)CFDictionaryGetValue(element, CFSTR(kIOHIDElementUsagePageKey));
        if (!number) continue;
        CFNumberGetValue(number, kCFNumberSInt32Type, &newElement.usagePage);

        /* Read the element's usage (second level category describing the type of
         element---kHIDUsage_GD_Keyboard, for example) */
        number = (CFNumberRef)CFDictionaryGetValue(element, CFSTR(kIOHIDElementUsageKey));
        if (!number) continue;
        CFNumberGetValue(number, kCFNumberSInt32Type, &newElement.usage);

        /* Read the cookie (unique identifier) for the element */
        number = (CFNumberRef)CFDictionaryGetValue(element, CFSTR(kIOHIDElementCookieKey));
        if (!number) continue;
        CFNumberGetValue(number, kCFNumberIntType, &(newElement.cookie));

        /* Determine what type of element this is---button, Axis, etc. */
        number = (CFNumberRef)CFDictionaryGetValue(element, CFSTR(kIOHIDElementTypeKey));
        if (!number) continue;
        CFNumberGetValue(number, kCFNumberIntType, &(newElement.type));

        /* Pay attention to X/Y coordinates of a pointing device and
         the first/second mouse button.  For other elements, go on to the
         next element. */

        if (!acceptHidElement(&newElement))
            continue;

        /* Add this element to the hidElements dictionary. */
        CFMutableDataRef newData = CFDataCreateMutable(kCFAllocatorDefault, sizeof(HIDElement));
        if (!newData) continue;
        bcopy(&newElement, CFDataGetMutableBytePtr(newData), sizeof(HIDElement));

        number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &newElement.cookie);
        if (!number)  continue;
        CFDictionarySetValue(hidElements, number, newData);
        CFRelease(number);
        CFRelease(newData);
    }

FIND_ELEMENT_CLEANUP:
    if (elementArray)
        CFRelease(elementArray);

    if (CFDictionaryGetCount(hidElements) == 0)
        CFRelease(hidElements);
    else
        hidDataRef->hidElementDictionary = hidElements;

    return hidDataRef->hidElementDictionary;
}

//---------------------------------------------------------------------------
// DeviceNotification
//
// This routine will get called whenever any kIOGeneralInterest notification
// happens.
//---------------------------------------------------------------------------

static void DeviceNotification(void *refCon, io_service_t service,
                               natural_t messageType, void *messageArgument)
{
    HIDDataRef hidDataRef = refCon;

    /* Check to see if a device went away and clean up. */
    if (!hidDataRef)
        return;

    if (messageType != kIOMessageServiceIsTerminated)
        return;

    IOHIDQueueInterface **q = hidDataRef->hidQueueInterface;
    IOHIDDeviceInterface122 **d = hidDataRef->hidDeviceInterface;

    if (q) {
        (*(q))->stop((q));
        (*(q))->dispose((q));
        (*(q))->Release (q);
        hidDataRef->hidQueueInterface = NULL;
    }

    if (d != NULL) {
        (*(d))->close (d);
        (*(d))->Release (d);
        hidDataRef->hidDeviceInterface = NULL;
    }

    if (hidDataRef->notification) {
        IOObjectRelease(hidDataRef->notification);
        hidDataRef->notification = 0;
    }
}

//---------------------------------------------------------------------------
// HIDDeviceAdded
//
// This routine is the callback for our IOServiceAddMatchingNotification.
// When we get called we will look at all the devices that were added and
// we will:
//
// Create some private data to relate to each device
//
// Submit an IOServiceAddInterestNotification of type kIOGeneralInterest for
// this device using the refCon field to store a pointer to our private data.
// When we get called with this interest notification, we can grab the refCon
// and access our private data.
//---------------------------------------------------------------------------

static void HIDDeviceAdded(void *refCon, io_iterator_t iterator)
{
    io_object_t hidDevice = 0;

    /* Interate through all the devices that matched */
    while (0 != (hidDevice = IOIteratorNext(iterator))) {
        // Create the CF plugin for this device
        SInt32 score;
        IOCFPlugInInterface **plugInInterface = NULL;
        if (kIOReturnSuccess != IOCreatePlugInInterfaceForService(hidDevice, kIOHIDDeviceUserClientTypeID,
                                               kIOCFPlugInInterfaceID, &plugInInterface, &score))
            goto HIDDEVICEADDED_NONPLUGIN_CLEANUP;

        /* Obtain a device interface structure (hidDeviceInterface). */
        IOHIDDeviceInterface122 **hidDeviceInterface = NULL;
        HRESULT result = (*plugInInterface)->QueryInterface(plugInInterface, CFUUIDGetUUIDBytes(kIOHIDDeviceInterfaceID122),
                                                    (LPVOID *)&hidDeviceInterface);

        // Got the interface
        HIDDataRef hidDataRef = NULL;
        if (result != S_OK || !hidDeviceInterface)
            goto HIDDEVICEADDED_FAIL;

        /* Create a custom object to keep data around for later. */
        hidDataRef = calloc(1, sizeof(HIDData));
        hidDataRef->hidDeviceInterface = hidDeviceInterface;

        /* Open the device interface. */
        result = (*hidDeviceInterface)->open(hidDeviceInterface, kIOHIDOptionsTypeSeizeDevice);

        if (result != S_OK)
            goto HIDDEVICEADDED_FAIL;

        /* Find the HID elements for this device and set up a receive queue. */
        if (!FindHIDElements(hidDataRef))
            goto HIDDEVICEADDED_FAIL;
        SetupQueue(hidDataRef);

#ifdef DEBUG
        printf("Please touch screen to continue.\n\n");
#endif

        /* Register an interest in finding out anything that happens with this device (disconnection, for example) */
        IOServiceAddInterestNotification(gNotifyPort, hidDevice,
                kIOGeneralInterest, DeviceNotification,
                hidDataRef, &(hidDataRef->notification));

        goto HIDDEVICEADDED_CLEANUP;

    HIDDEVICEADDED_FAIL:
        // Failed to allocated a UPS interface.  Do some cleanup
        if (hidDeviceInterface) {
            (*hidDeviceInterface)->Release(hidDeviceInterface);
            hidDeviceInterface = NULL;
        }

        free (hidDataRef);

    HIDDEVICEADDED_CLEANUP:
        // Clean up
        (*plugInInterface)->Release(plugInInterface);

    HIDDEVICEADDED_NONPLUGIN_CLEANUP:
        IOObjectRelease(hidDevice);
    }
}

//---------------------------------------------------------------------------
// InitHIDNotifications
//
// This routine just creates our master port for IOKit and turns around
// and calls the routine that will alert us when a HID Device is plugged in.
//---------------------------------------------------------------------------

static void InitHIDNotifications(SInt32 vendorID, SInt32 productID)
{
    mach_port_t masterPort;
    if (IOMasterPort(bootstrap_port, &masterPort) || !masterPort)
        return;

    // Create a notification port and add its run loop event source to our run loop
    // This is how async notifications get set up.
    gNotifyPort = IONotificationPortCreate(masterPort);
    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                       IONotificationPortGetRunLoopSource(gNotifyPort),
                       kCFRunLoopDefaultMode);

    // Create the IOKit notifications that we need
    /* Create a matching dictionary that (initially) matches all HID devices. */
    CFMutableDictionaryRef matchingDict = IOServiceMatching(kIOHIDDeviceKey);
    if (!matchingDict)
        return;

    /* Create objects for product and vendor IDs. */
    CFNumberRef refProdID = CFNumberCreate (kCFAllocatorDefault, kCFNumberIntType, &productID);
    CFNumberRef refVendorID = CFNumberCreate (kCFAllocatorDefault, kCFNumberIntType, &vendorID);

    /* Add objects to matching dictionary and clean up. */
    CFDictionarySetValue (matchingDict, CFSTR (kIOHIDVendorIDKey), refVendorID);
    CFDictionarySetValue (matchingDict, CFSTR (kIOHIDProductIDKey), refProdID);

    CFRelease(refProdID);
    CFRelease(refVendorID);

    // Now set up a notification to be called when a device is first matched by I/O Kit.
    // Note that this will not catch any devices that were already plugged in so we take
    // care of those later.
    io_iterator_t gAddedIter = 0;
    if (kIOReturnSuccess == IOServiceAddMatchingNotification(
            gNotifyPort, kIOFirstMatchNotification, matchingDict,
            HIDDeviceAdded, NULL, &gAddedIter))
        HIDDeviceAdded(NULL, gAddedIter);
}

int main (int argc, const char * argv[])
{
    int vid = -1;
    int pid = -1;

    if (argc == 3) {
        char *end;
        unsigned long l = strtoul(argv[1], &end, 16);
        if (*end == '\0' && l < 0x10000)
            vid = (int)l;
        l = strtoul(argv[2], &end, 16);
        if (*end == '\0' && l < 0x10000)
            pid = (int)l;
    }

    if (vid < 0 || pid < 0) {
        fprintf(stderr, "Usage: %s <VID> <PID>\n", argv[0]);
        return 1;
    }

    if (!CGMainDisplayID()) {
        fprintf(stderr, "No display found\n");
        return 1;
    }

    gLock = [[NSLock alloc] init];
    InitHIDNotifications(vid, pid);
    CFRunLoopRun();

    return 0;
}
