#import "CallingSyntheticAudioDevice.h"
#import <mach/mach_time.h>
#import <math.h>

static const double CallingSampleRate = 48000.0;
enum { CallingFramesPerBuffer = 480 };

@interface CallingSyntheticAudioDevice () {
    NSCondition *_condition;
    id<RTCAudioDeviceDelegate> _audioDelegate;
    NSThread *_audioThread;
    BOOL _initialized;
    BOOL _playoutInitialized;
    BOOL _recordingInitialized;
    BOOL _playing;
    BOOL _recording;
    BOOL _stopping;
    BOOL _threadFinished;
    double _toneFrequency;
    double _expectedFrequency;
    uint64_t _samplePosition;
    uint64_t _generatedFrames;
    uint64_t _playoutFrames;
    uint64_t _callbackErrors;
    double _playoutEnergy;
    double _expectedToneEnergy;
    double _ownToneEnergy;
}
@end

@implementation CallingSyntheticAudioDevice

- (instancetype)initWithToneFrequency:(double)toneFrequency
                  expectedFrequency:(double)expectedFrequency {
    self = [super init];
    if (self) {
        _condition = [[NSCondition alloc] init];
        _toneFrequency = toneFrequency;
        _expectedFrequency = expectedFrequency;
        _threadFinished = YES;
    }
    return self;
}

- (double)deviceInputSampleRate { return CallingSampleRate; }
- (double)deviceOutputSampleRate { return CallingSampleRate; }
- (NSTimeInterval)inputIOBufferDuration { return 0.01; }
- (NSTimeInterval)outputIOBufferDuration { return 0.01; }
- (NSInteger)inputNumberOfChannels { return 1; }
- (NSInteger)outputNumberOfChannels { return 1; }
- (NSTimeInterval)inputLatency { return 0; }
- (NSTimeInterval)outputLatency { return 0; }

- (BOOL)isInitialized {
    [_condition lock];
    BOOL value = _initialized;
    [_condition unlock];
    return value;
}

- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate {
    [_condition lock];
    if (_initialized || !_threadFinished) {
        [_condition unlock];
        return NO;
    }
    _audioDelegate = delegate;
    _initialized = YES;
    _stopping = NO;
    _threadFinished = NO;
    _audioThread = [[NSThread alloc] initWithTarget:self selector:@selector(runAudio) object:nil];
    _audioThread.name = @"Calling synthetic PCM";
    [_audioThread start];
    [_condition unlock];
    return YES;
}

- (BOOL)terminateDevice {
    // WebRTC may terminate its ADM on the owner thread. Do not block that thread
    // while a final callback finishes. The test explicitly joins in its teardown.
    [_condition lock];
    _initialized = NO;
    _playing = NO;
    _recording = NO;
    _playoutInitialized = NO;
    _recordingInitialized = NO;
    _stopping = YES;
    [_condition broadcast];
    [_condition unlock];
    return YES;
}

- (BOOL)isPlayoutInitialized {
    [_condition lock];
    BOOL value = _playoutInitialized;
    [_condition unlock];
    return value;
}

- (BOOL)initializePlayout {
    [_condition lock];
    _playoutInitialized = _initialized;
    BOOL value = _playoutInitialized;
    [_condition unlock];
    return value;
}

- (BOOL)isPlaying {
    [_condition lock];
    BOOL value = _playing;
    [_condition unlock];
    return value;
}

- (BOOL)startPlayout {
    [_condition lock];
    _playing = _playoutInitialized && !_stopping;
    BOOL value = _playing;
    [_condition unlock];
    return value;
}

- (BOOL)stopPlayout {
    [_condition lock];
    _playing = NO;
    [_condition unlock];
    return YES;
}

- (BOOL)isRecordingInitialized {
    [_condition lock];
    BOOL value = _recordingInitialized;
    [_condition unlock];
    return value;
}

- (BOOL)initializeRecording {
    [_condition lock];
    _recordingInitialized = _initialized;
    BOOL value = _recordingInitialized;
    [_condition unlock];
    return value;
}

- (BOOL)isRecording {
    [_condition lock];
    BOOL value = _recording;
    [_condition unlock];
    return value;
}

- (BOOL)startRecording {
    [_condition lock];
    _recording = _recordingInitialized && !_stopping;
    BOOL value = _recording;
    [_condition unlock];
    return value;
}

- (BOOL)stopRecording {
    [_condition lock];
    _recording = NO;
    [_condition unlock];
    return YES;
}

- (void)notifyUnchangedAudioParameters {
    [_condition lock];
    id<RTCAudioDeviceDelegate> delegate = _audioDelegate;
    BOOL running = _initialized && !_stopping;
    [_condition unlock];
    if (running) {
        [delegate dispatchSync:^{
            [delegate notifyAudioInputParametersChange];
            [delegate notifyAudioOutputParametersChange];
        }];
    }
}

- (NSDictionary<NSString *, NSNumber *> *)snapshot {
    [_condition lock];
    NSDictionary *result = @{
        @"generatedFrames": @(_generatedFrames),
        @"playoutFrames": @(_playoutFrames),
        @"callbackErrors": @(_callbackErrors),
        @"playoutEnergy": @(_playoutEnergy),
        @"expectedToneEnergy": @(_expectedToneEnergy),
        @"ownToneEnergy": @(_ownToneEnergy),
        @"recording": @(_recording),
        @"playing": @(_playing),
        @"threadFinished": @(_threadFinished)
    };
    [_condition unlock];
    return result;
}

- (BOOL)stopAndWait:(NSTimeInterval)timeout {
    [self terminateDevice];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    [_condition lock];
    while (!_threadFinished && [_condition waitUntilDate:deadline]) {}
    BOOL finished = _threadFinished;
    [_condition unlock];
    return finished;
}

- (void)runAudio {
    @autoreleasepool {
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        uint64_t interval = (uint64_t)(10000000.0 * timebase.denom / timebase.numer);
        uint64_t nextTick = mach_absolute_time();
        while (YES) {
            @autoreleasepool {
                [_condition lock];
                BOOL stopping = _stopping;
                BOOL recording = _recording;
                BOOL playing = _playing;
                id<RTCAudioDeviceDelegate> delegate = _audioDelegate;
                [_condition unlock];
                if (stopping) { break; }

                AudioTimeStamp timestamp = {0};
                timestamp.mSampleTime = (Float64)_samplePosition;
                timestamp.mHostTime = mach_absolute_time();
                timestamp.mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
                AudioUnitRenderActionFlags flags = 0;
                uint64_t errors = 0;
                uint64_t generated = 0;
                uint64_t played = 0;
                double energy = 0;
                double expectedEnergy = 0;
                double ownEnergy = 0;

                if (recording) {
                    int16_t samples[CallingFramesPerBuffer];
                    for (UInt32 index = 0; index < CallingFramesPerBuffer; index++) {
                        double t = (double)(_samplePosition + index) / CallingSampleRate;
                        double envelope = 0.22 + 0.03 * sin(2 * M_PI * 3 * t);
                        samples[index] = (int16_t)(32767 * envelope * sin(2 * M_PI * _toneFrequency * t));
                    }
                    AudioBufferList buffer = { .mNumberBuffers = 1 };
                    buffer.mBuffers[0] = (AudioBuffer){1, sizeof(samples), samples};
                    OSStatus status = delegate.deliverRecordedData(
                        &flags, &timestamp, 0, CallingFramesPerBuffer, &buffer, NULL, nil);
                    errors += status != noErr;
                    generated = CallingFramesPerBuffer;
                }

                if (playing) {
                    int16_t samples[CallingFramesPerBuffer] = {0};
                    AudioBufferList buffer = { .mNumberBuffers = 1 };
                    buffer.mBuffers[0] = (AudioBuffer){1, sizeof(samples), samples};
                    OSStatus status = delegate.getPlayoutData(
                        &flags, &timestamp, 0, CallingFramesPerBuffer, &buffer);
                    errors += status != noErr;
                    if (status == noErr) {
                        double expectedSin = 0, expectedCos = 0, ownSin = 0, ownCos = 0;
                        for (UInt32 index = 0; index < CallingFramesPerBuffer; index++) {
                            double sample = (double)samples[index] / 32768;
                            double t = (double)index / CallingSampleRate;
                            energy += sample * sample;
                            expectedSin += sample * sin(2 * M_PI * _expectedFrequency * t);
                            expectedCos += sample * cos(2 * M_PI * _expectedFrequency * t);
                            ownSin += sample * sin(2 * M_PI * _toneFrequency * t);
                            ownCos += sample * cos(2 * M_PI * _toneFrequency * t);
                        }
                        // Phase independent matched tone energy for this ten millisecond block.
                        expectedEnergy = 2 * (expectedSin * expectedSin + expectedCos * expectedCos) / CallingFramesPerBuffer;
                        ownEnergy = 2 * (ownSin * ownSin + ownCos * ownCos) / CallingFramesPerBuffer;
                        played = CallingFramesPerBuffer;
                    }
                }
                _samplePosition += CallingFramesPerBuffer;
                [_condition lock];
                _generatedFrames += generated;
                _playoutFrames += played;
                _callbackErrors += errors;
                _playoutEnergy += energy;
                _expectedToneEnergy += expectedEnergy;
                _ownToneEnergy += ownEnergy;
                [_condition unlock];

                nextTick += interval;
                uint64_t now = mach_absolute_time();
                // Do not create a burst of RTP after a suspended simulator.
                if (nextTick < now) { nextTick = now + interval; }
                mach_wait_until(nextTick);
            }
        }
        [_condition lock];
        _audioDelegate = nil;
        _audioThread = nil;
        _threadFinished = YES;
        [_condition broadcast];
        [_condition unlock];
    }
}

@end
