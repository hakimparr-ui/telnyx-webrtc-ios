This harness compiles the SDK source in this checkout and executes the native
audio ownership tests against WebRTC 124.0.0 and Starscream 4.0.8. Those versions
match the iPhone application's dependency pins. It does not connect to a
provider, negotiate a call or use a telephone number.

On an Apple test worker with CocoaPods and its xcodeproj Ruby gem, generate the
project into an owned temporary directory outside a synced Documents folder.
Register the native job through the existing worker owner before installation
or compilation. Supply an owned iOS simulator to xcodebuild.

```sh
ruby tools/calling-audio-regression/generate_project.rb "$CALLING_TEST_DIRECTORY"
cd "$CALLING_TEST_DIRECTORY"
pod install --no-repo-update
xcodebuild -workspace CallingAudioRegression.xcworkspace \
  -scheme CallingAudioOwnershipTests -configuration Debug \
  -destination "platform=iOS Simulator,id=$CALLING_SIMULATOR_ID" \
  -derivedDataPath "$CALLING_DERIVED_DATA" \
  -resultBundlePath "$CALLING_RESULT_BUNDLE" \
  -jobs 2 -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

The tests execute real WebRTC audio tracks and the real AVAudioSession. They
cover application ownership of microphone state, user mute intent, deferred
audio activation and speaker selection. The route recorder forwards each
observed call to AVAudioSession and restores its instrumentation after the
test. Simulator checks do not establish microphone capture or audible speech
at a remote phone. A physical call remains necessary for that acceptance.

Retain the exact source identity, dependency lock and XCTest result. Shut down
and remove only the simulator created for this job, verify the job's processes
have exited, and remove the generated project and intermediates before releasing
the native worker record.
