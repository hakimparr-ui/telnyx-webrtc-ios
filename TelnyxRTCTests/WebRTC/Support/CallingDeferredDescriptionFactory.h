#import <WebRTC/WebRTC.h>

NS_ASSUME_NONNULL_BEGIN

// Runs real WebRTC SDP work, but lets a lifecycle test release its completion
// after a deterministic terminal event. Only connections from this factory are
// instrumented; no production class method or shared factory is changed.
@interface CallingDeferredDescriptionFactory : RTCPeerConnectionFactory
@property(nonatomic, readonly) BOOL hasDeferredRemoteCompletion;
- (void)releaseRemoteDescriptionCompletion;
@end

NS_ASSUME_NONNULL_END
