#import <Foundation/Foundation.h>
#import <WebRTC/RTCAudioDevice.h>

NS_ASSUME_NONNULL_BEGIN

// An in memory audio device for real WebRTC transport tests. It never opens a
// microphone or speaker. Only aggregate measurements leave its callback thread.
@interface CallingSyntheticAudioDevice : NSObject <RTCAudioDevice>

- (instancetype)initWithToneFrequency:(double)toneFrequency
                  expectedFrequency:(double)expectedFrequency;
- (NSDictionary<NSString *, NSNumber *> *)snapshot;
- (void)notifyUnchangedAudioParameters;
- (BOOL)stopAndWait:(NSTimeInterval)timeout;

@end

NS_ASSUME_NONNULL_END
