//  AirPlayReceiverBridge.h
//  C & Objective-C bridge exposing the local MyPEQ MediaDevice loopback receiver
//  (LocalLink TCP 127.0.0.1:47101 / ETLinkReceiver) to Swift (PEQAudioEngine).

#ifndef AirPlayReceiverBridge_h
#define AirPlayReceiverBridge_h

#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Starts the local loopback receiver socket (127.0.0.1:47101).
bool MyPEQReceiverStart(void);

/// Stops the loopback receiver socket.
void MyPEQReceiverStop(void);

/// Returns true while the receiver socket is listening.
bool MyPEQReceiverIsRunning(void);

/// Returns true while MyPEQExtension or a LocalLink sender is actively streaming PCM frames.
bool MyPEQReceiverIsStreaming(void);

/// Returns the active receiver sample rate in Hz (44100.0 or 48000.0).
double MyPEQReceiverGetSampleRate(void);

/// Updates the receiver nominal sample rate in Hz (44100.0 or 48000.0).
void MyPEQReceiverSetSampleRate(double sampleRate);

/// Total stereo frames received since startup.
uint64_t MyPEQReceiverGetReceivedFrames(void);

/// Current unread stereo frames queued in the jitter buffer.
uint32_t MyPEQReceiverGetBufferedFrames(void);

/// Reads interleaved stereo Float32 PCM frames for the render callback (fills silence on underrun).
uint32_t MyPEQReceiverReadPCM(float * _Nonnull outInterleavedStereo, uint32_t frameCount);

/// Pushes interleaved Float32 PCM frames directly into the receiver ring buffer.
void MyPEQReceiverPushPCM(const float * _Nonnull interleavedStereo,
                          uint32_t frameCount,
                          uint32_t channels,
                          double sampleRate);

/// Returns the advertised output device stem/name ("MyPEQ").
const char * _Nonnull MyPEQReceiverGetServiceName(void);

#ifdef __cplusplus
}
#endif

@interface MyPEQAirPlayBridge : NSObject

@property (class, readonly) MyPEQAirPlayBridge *shared;
@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly) BOOL streaming;
@property (nonatomic) double sampleRate;
@property (nonatomic, readonly) uint64_t receivedFrames;
@property (nonatomic, readonly) uint32_t bufferedFrames;

- (BOOL)start;
- (void)stop;
- (uint32_t)readInterleaved:(float *)outInterleavedStereo frames:(uint32_t)frameCount;
- (void)pushInterleaved:(const float *)interleavedStereo
                 frames:(uint32_t)frameCount
               channels:(uint32_t)channels
             sampleRate:(double)sampleRate;

@end

NS_ASSUME_NONNULL_END

#endif /* AirPlayReceiverBridge_h */
