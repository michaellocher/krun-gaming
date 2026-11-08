#pragma once
#import <Cocoa/Cocoa.h>
#include <stdint.h>

// Registers a virtio-input keyboard and an absolute pointer (tablet) with libkrun; returns < 0 on error.
int input_add_devices(uint32_t ctx);

// Content view for the VM window: forwards keyboard and mouse events to the guest devices.
@interface InputView : NSView
@end
