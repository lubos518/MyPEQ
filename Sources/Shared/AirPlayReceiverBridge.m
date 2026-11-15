//  AirPlayReceiverBridge.m
//  Bridges ETLinkReceiver's Float32 PCM loopback ring buffer to PEQAudioEngine.swift
//  while MyPEQExtension (MediaDeviceExtension) advertises the "MyPEQ" output device.

#import "AirPlayReceiverBridge.h"
#import "ETNames.h"
#import "LocalLink.h"
#import <os/log.h>
#import <stdatomic.h>

static os_log_t MyPEQBridgeLog(void) {
    static os_log_t logger;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logger = os_log_create("com.mypeq.app", "receiver-bridge");
    });
    return logger;
}

@implementation MyPEQAirPlayBridge {
    _Atomic bool _running;
}

+ (MyPEQAirPlayBridge *)shared {
    static MyPEQAirPlayBridge *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[MyPEQAirPlayBridge alloc] init];
    });
    return instance;
}

- (BOOL)running {
    return atomic_load_explicit(&_running, memory_order_acquire) && ETLinkReceiver.shared.listening;
}

- (BOOL)streaming {
    return ETLinkReceiver.shared.hasPeer;
}

- (double)sampleRate {
    return ETLinkReceiver.shared.sampleRate;
}

- (void)setSampleRate:(double)sampleRate {
    ETLinkReceiver.shared.sampleRate = sampleRate;
}

- (uint64_t)receivedFrames {
    return ETLinkReceiver.shared.receivedFrames;
}

- (uint32_t)bufferedFrames {
    return ETLinkReceiver.shared.bufferedFrames;
}

- (BOOL)start {
    BOOL ok = [ETLinkReceiver.shared start];
    if (!ok) {
        os_log_error(MyPEQBridgeLog(), "Failed to start ETLinkReceiver on port %d", ET_LINK_PORT);
        atomic_store_explicit(&_running, false, memory_order_release);
        return NO;
    }

    atomic_store_explicit(&_running, true, memory_order_release);
    os_log_info(MyPEQBridgeLog(), "ETLinkReceiver started on %s:%d for %{public}s",
                ET_LINK_HOST, ET_LINK_PORT, ET_ROUTE_NAME);
    return YES;
}

- (void)stop {
    atomic_store_explicit(&_running, false, memory_order_release);
    [ETLinkReceiver.shared stop];
}

- (uint32_t)readInterleaved:(float *)outInterleavedStereo frames:(uint32_t)frameCount {
    return [ETLinkReceiver.shared readInterleaved:outInterleavedStereo frames:frameCount];
}

- (void)pushInterleaved:(const float *)interleavedStereo
                 frames:(uint32_t)frameCount
               channels:(uint32_t)channels
             sampleRate:(double)sampleRate {
    if (sampleRate > 0.0) {
        ETLinkReceiver.shared.sampleRate = sampleRate;
    }
    [ETLinkReceiver.shared pushInterleaved:interleavedStereo frames:frameCount channels:channels];
}

@end

#pragma mark - C Bridge Entrypoints

bool MyPEQReceiverStart(void) {
    return [MyPEQAirPlayBridge.shared start];
}

void MyPEQReceiverStop(void) {
    [MyPEQAirPlayBridge.shared stop];
}

bool MyPEQReceiverIsRunning(void) {
    return MyPEQAirPlayBridge.shared.running;
}

bool MyPEQReceiverIsStreaming(void) {
    return MyPEQAirPlayBridge.shared.streaming;
}

double MyPEQReceiverGetSampleRate(void) {
    return MyPEQAirPlayBridge.shared.sampleRate;
}

void MyPEQReceiverSetSampleRate(double sampleRate) {
    MyPEQAirPlayBridge.shared.sampleRate = sampleRate;
}

uint64_t MyPEQReceiverGetReceivedFrames(void) {
    return MyPEQAirPlayBridge.shared.receivedFrames;
}

uint32_t MyPEQReceiverGetBufferedFrames(void) {
    return MyPEQAirPlayBridge.shared.bufferedFrames;
}

uint32_t MyPEQReceiverReadPCM(float * _Nonnull outInterleavedStereo, uint32_t frameCount) {
    return [MyPEQAirPlayBridge.shared readInterleaved:outInterleavedStereo frames:frameCount];
}

void MyPEQReceiverPushPCM(const float * _Nonnull interleavedStereo,
                          uint32_t frameCount,
                          uint32_t channels,
                          double sampleRate) {
    [MyPEQAirPlayBridge.shared pushInterleaved:interleavedStereo
                                        frames:frameCount
                                      channels:channels
                                    sampleRate:sampleRate];
}

const char * _Nonnull MyPEQReceiverGetServiceName(void) {
    return ET_ROUTE_NAME;
}
