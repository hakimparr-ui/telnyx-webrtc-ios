#import "CallingDeferredDescriptionFactory.h"
#import <objc/runtime.h>

static char CallingDescriptionGateKey;
typedef void (*CallingSetDescriptionIMP)(id, SEL, RTCSessionDescription *, void (^)(NSError *));

@interface CallingDescriptionGate : NSObject
@property(nonatomic) IMP originalImplementation;
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, copy) void (^completion)(void);
@end

@implementation CallingDescriptionGate
- (instancetype)init {
    self = [super init];
    if (self) { _lock = [[NSLock alloc] init]; }
    return self;
}
@end

static void CallingSetRemoteDescription(id object, SEL selector, RTCSessionDescription *description,
                                        void (^completion)(NSError *)) {
    CallingDescriptionGate *gate = objc_getAssociatedObject(object, &CallingDescriptionGateKey);
    CallingSetDescriptionIMP original = (CallingSetDescriptionIMP)gate.originalImplementation;
    original(object, selector, description, ^(NSError *error) {
        [gate.lock lock];
        gate.completion = ^{ completion(error); };
        [gate.lock unlock];
    });
}

@interface CallingDeferredDescriptionFactory ()
@property(nonatomic, strong) CallingDescriptionGate *descriptionGate;
@end

@implementation CallingDeferredDescriptionFactory

- (RTCPeerConnection *)peerConnectionWithConfiguration:(RTCConfiguration *)configuration
                                          constraints:(RTCMediaConstraints *)constraints
                                             delegate:(id<RTCPeerConnectionDelegate>)delegate {
    RTCPeerConnection *connection = [super peerConnectionWithConfiguration:configuration
                                                             constraints:constraints delegate:delegate];
    if (!connection) { return nil; }
    Class originalClass = object_getClass(connection);
    SEL selector = @selector(setRemoteDescription:completionHandler:);
    Method method = class_getInstanceMethod(originalClass, selector);
    NSAssert(method != NULL, @"The pinned WebRTC SDP method must exist");
    Class gatedClass = NSClassFromString(@"CallingDeferredRemoteDescriptionPeer");
    if (!gatedClass) {
        gatedClass = objc_allocateClassPair(originalClass, "CallingDeferredRemoteDescriptionPeer", 0);
        NSAssert(gatedClass != Nil, @"The isolated connection class must be created");
        class_addMethod(gatedClass, selector, (IMP)CallingSetRemoteDescription, method_getTypeEncoding(method));
        objc_registerClassPair(gatedClass);
    }
    CallingDescriptionGate *gate = [[CallingDescriptionGate alloc] init];
    gate.originalImplementation = method_getImplementation(method);
    self.descriptionGate = gate;
    objc_setAssociatedObject(connection, &CallingDescriptionGateKey, gate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    object_setClass(connection, gatedClass);
    return connection;
}

- (BOOL)hasDeferredRemoteCompletion {
    CallingDescriptionGate *gate = self.descriptionGate;
    [gate.lock lock];
    BOOL ready = gate.completion != nil;
    [gate.lock unlock];
    return ready;
}

- (void)releaseRemoteDescriptionCompletion {
    CallingDescriptionGate *gate = self.descriptionGate;
    [gate.lock lock];
    void (^completion)(void) = gate.completion;
    gate.completion = nil;
    [gate.lock unlock];
    if (completion) { completion(); }
}

@end
