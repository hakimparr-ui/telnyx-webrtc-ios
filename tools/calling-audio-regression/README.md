This harness compiles the SDK source in this checkout against WebRTC 124.0.0
and Starscream 4.0.8. Those versions match the iPhone application's dependency
pins. It runs native audio ownership checks and two actual WebRTC peers using
synthetic audio. It does not connect to a provider or use a telephone number.

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
test.

The RTP tests inject a synthetic audio device through the internal factory
initializer. Each peer sends a distinct generated tone and measures decoded
PCM from the other peer. No microphone is opened and no PCM recording is
retained. The tests use the actual incoming Call.answer implementation and its
answer and ICE messages through an in memory signaling socket. Host candidates
stay local and no STUN or TURN server is configured.

Each long call runs beyond two minutes. One offer places G722 before Opus and
checks that the incoming preference selects Opus. A second offers only G722
and checks that the same preference retains a working fallback. Both measure
decoded audio and increasing RTP counters through receiver and speaker
category changes, delayed ICE recovery callbacks and user mute and unmute.
The ICE callbacks are injected notifications on an established transport.
These checks do not simulate packet loss, the operating system suspending an
app or an actual network switch. Separate assertions distinguish received BYE,
local hangup and acknowledgement of a queued hangup through real Call delegates.

Each negotiated call retains the actual original offer, effective SDK offer
and emitted answer as bounded audio payload and codec ordering. Addresses,
ICE credentials, fingerprints and other SDP contents are omitted. Measurements
record audio and lifecycle checks separately from codec format checks, and any
audio failure also emits a short CALLING_MEDIA_CHECK_FAILURE record. A focused
negotiation run can select the ATTACH dispatcher case and
`testIncomingNegotiatesPreferredOpusWhenG722IsOfferedFirst` before the full
endurance suite. The long cases still run beyond two minutes.

The custom audio device measures encoding, transport and decoding. It does not
test the hardware microphone, CallKit activation or carrier transcoding.
Simulator success does not establish audible speech at a remote phone.

The generator includes Calling prefixed XCTest files in the SDK WebRTC test
directory. Optional arguments can add an app helper with `--source PATH`, its
test with `--test PATH` and a sanitized JSON fixture with `--fixture PATH`.
Every supplied file must exist. The existing scheme name remains unchanged.
An app helper that its tests reference directly can also be supplied with
`--test PATH` so both compile in the test target. The `--snapshot-source PATH`
option extracts the exact production TelnyxPstnNativeQualitySnapshot declaration
into that target and records the source commit and file hashes in a JSON
resource. The extraction adds imports and does not rewrite the implementation.

Retain the exact source identity, dependency lock and XCTest result. Shut down
and remove only the simulator created for this job, verify the job's processes
have exited, and remove the generated project and intermediates before releasing
the native worker record.
