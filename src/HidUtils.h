/*
* Copyright (c) 2013 Alexander Tarasikov
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

#ifndef _HidUtils_h
#define _HidUtils_h

#include <IOKit/hid/IOHIDLib.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hid/IOHIDUsageTables.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <IOKit/hidsystem/IOHIDShared.h>
#include <IOKit/hidsystem/IOHIDParameter.h>

typedef struct HIDData
{
    io_object_t             notification;
    IOHIDDeviceInterface122 **hidDeviceInterface;
    IOHIDQueueInterface     **hidQueueInterface;
    CFDictionaryRef         hidElementDictionary;
    CFRunLoopSourceRef      eventSource;
} HIDData;

typedef HIDData *HIDDataRef;

typedef struct HIDElement {
    SInt32              currentValue;
    SInt32              usagePage;
    SInt32              usage;
    IOHIDElementType    type;
    IOHIDElementCookie  cookie;
    HIDDataRef          owner;
}HIDElement;

typedef HIDElement *HIDElementRef;

typedef enum {
    UP,
    DOWN,
    NO_CHANGE,
} ButtonState;

#endif
