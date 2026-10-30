import argparse
import hashlib
import io
import json
import os
import plistlib
import xml.etree.ElementTree as ET
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tarfile
import tempfile
import time

COMMIT = '19c5abf6836a65d94eef83c0fd364d40c25f2dc3'
BASELINE = '9fe1558bbf1c27e4e3aee290f6f392802aaaebe7'
REPOSITORY = Path('/Users/hakimparr/Developer/Projects/UpgradeOS/telnyx-webrtc-ios-decline-audit')
STATE = Path('/Users/hakimparr/.local/state/uos-calling-public-release-20261007')
SOURCE_HASHES = {'corrected': {'TelnyxRTC/Telnyx/TxClient.swift': '9c0f214094054314c80a0652bb08c7b584ba981008082eb56876f8b9c44ecc51', 'TelnyxRTCTests/WebRTC/CallingCallKitAudioSessionTests.swift': '3b1048ca8a5163686fcb453b31b2ce9a191b7b7b7026dbf975ce6735d5f563a0'}, 'baseline': {'TelnyxRTC/Telnyx/TxClient.swift': '6609295f1216d280ded1897e362e06686aa18b15307e282e4bb360a61bc9106f', 'TelnyxRTCTests/WebRTC/CallingCallKitAudioSessionTests.swift': '3b1048ca8a5163686fcb453b31b2ce9a191b7b7b7026dbf975ce6735d5f563a0'}}
CASES = ['testPreparationConfiguresRecordingWithoutActivationOrDevicePermission', 'testPreparationClearsInheritedMixingAndSpeakerDefaults', 'testPreparationReturnsTheConfigurationErrorWithoutAcceptingAudio', 'testActivationAndDeactivationOnlyReportTheExternalOwner', 'testRepeatedActivationNotifiesAgainWithoutAddingAnOwnerOrDisablingAudio', 'testCallKitReactivationClearsInterruptionWithTheEnabledFlagAlreadyTrue', 'testPropertyAndCallbackShareOneBalancedActivation', 'testClientWithoutActivationCannotReleaseAnExistingOwner', 'testSynchronousDelegateRevocationIsNotUndoneByActivation', 'testEngineStartupKeepsPreparedPolicyAndExternalOwner', 'testEngineStartupClearsInheritedGlobalOptions', 'testEngineBoundaryDetectsAChangedCurrentConfiguration']
BASELINE_FAILURES = ['testEngineStartupKeepsPreparedPolicyAndExternalOwner', 'testEngineStartupClearsInheritedGlobalOptions']
PODFILE = """source 'https://cdn.cocoapods.org/'
platform :ios, '12.0'
project 'TelnyxRTC.xcodeproj'
workspace 'PassiveInviteValidation'
use_frameworks!
target 'TelnyxRTC' do
  pod 'Starscream', '= 4.0.8'
  pod 'WebRTC-lib', '= 124.0.0'
  target 'TelnyxRTCTests' do
    inherit! :complete
  end
end
"""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read(command, cwd=None):
    return subprocess.check_output(command, cwd=cwd, text=True, timeout=40)


def process_rows():
    rows = []
    for line in read(['ps', '-axo', 'pid=,ppid=,pgid=,command=']).splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) == 4:
            rows.append({'pid': int(parts[0]), 'ppid': int(parts[1]), 'pgid': int(parts[2]), 'command': parts[3]})
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--apple-owner-settled', action='store_true', required=True)
    parser.add_argument('--previous-settled-receipt', type=Path, required=True)
    args = parser.parse_args()
    if not args.apple_owner_settled:
        raise RuntimeError('Existing Apple operation must have settled before this isolated validation')
    os.umask(0o077)
    stamp = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())
    evidence = STATE / ('sdk-callkit-engine-boundary-catalyst-validation-' + stamp)
    evidence.mkdir(mode=0o700)
    root = Path(tempfile.mkdtemp(prefix='uos-sdk-callkit-engine-boundary-', dir='/private/tmp'))
    root.chmod(0o700)
    source = root / 'source'
    source.mkdir(mode=0o700)
    active = None
    report = {
        'commit': COMMIT, 'pid': os.getpid(), 'pgid': os.getpgrp(), 'startedAt': stamp,
        'temporaryRoot': str(root), 'source': str(source), 'destination': 'platform=macOS,variant=Mac Catalyst',
        'children': [], 'status': 'preparing', 'scriptSha256': digest(Path(__file__).read_bytes()),
        'sourceRepositoryReadMode': 'git archive and git show exact pinned commit only',
        'realCredentialsUsed': False, 'providerCallsIssued': False, 'mediaPlaybackRequested': False,
    }
    env = {key: os.environ[key] for key in ['PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'DEVELOPER_DIR'] if key in os.environ}
    env.update(LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8', COCOAPODS_DISABLE_STATS='true', NSUnbufferedIO='YES')

    def save():
        (evidence / 'receipt.json').write_text(json.dumps(report, indent=2) + '\n')

    def stopped(signum, frame):
        raise RuntimeError('Validation interrupted by signal ' + str(signum))

    signal.signal(signal.SIGTERM, stopped)

    def run(command, name, timeout, allow_test_failure=False):
        nonlocal active
        with (evidence / (name + '.log')).open('wb') as log:
            active = subprocess.Popen(command, cwd=source, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            entry = {'name': name, 'pid': active.pid, 'pgid': active.pid, 'cwd': str(source), 'command': command, 'startedAt': time.time()}
            report['children'].append(entry)
            report['status'] = name
            save()
            print(json.dumps({'phase': name, 'pid': active.pid, 'pgid': active.pid, 'receipt': str(evidence / 'receipt.json')}), flush=True)
            try:
                entry['returnCode'] = active.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                entry['timedOut'] = True
                raise
            finally:
                entry['finishedAt'] = time.time()
                save()
            result = entry['returnCode']
            if result != 0 and not allow_test_failure:
                raise RuntimeError(name + ' failed with exit ' + str(result))
            active = None
            return result

    def verify_source(stage):
        actual = {path: digest((source / path).read_bytes()) for path in SOURCE_HASHES[stage]}
        if actual != SOURCE_HASHES[stage]:
            raise RuntimeError('Unexpected ' + stage + ' source hash')
        report[stage + 'SourceHashes'] = actual
        save()

    def verify_local_signatures(phase):
        products = root / 'DerivedData/Build/Products/Debug-maccatalyst'
        test_bundle = products / 'TelnyxRTCTests.xctest'
        web_rtc = test_bundle / 'Contents/Frameworks/WebRTC.framework'
        results = {}
        for target in [test_bundle, web_rtc]:
            if not target.exists():
                raise RuntimeError('Expected signed test product missing: ' + str(target))
            inspection = subprocess.run(['/usr/bin/codesign', '--display', '--verbose=4', str(target)],
                                        capture_output=True, text=True, timeout=30)
            details = inspection.stdout + inspection.stderr
            if inspection.returncode != 0 or 'Signature=adhoc' not in details or 'Authority=' in details:
                raise RuntimeError('Product is not signed with the required local ad hoc identity: ' + str(target))
            verification = subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(target)],
                                          capture_output=True, text=True, timeout=30)
            results[str(target.relative_to(products))] = {'inspection': details, 'verifyReturnCode': verification.returncode,
                'verification': verification.stdout + verification.stderr}
            if verification.returncode != 0:
                raise RuntimeError('Local test product signature verification failed: ' + str(target))
        report[phase + 'LocalSignatures'] = results
        (evidence / (phase + '-local-signatures.json')).write_text(json.dumps(results, indent=2) + '\n')
        save()

    def test_phase(name, selectors, expected_failures):
        bundle = evidence / (name + '.xcresult')
        command = ['xcodebuild', 'test', '-workspace', 'PassiveInviteValidation.xcworkspace',
                   '-scheme', 'TelnyxRTCTests', '-configuration', 'Debug', '-destination',
                   'platform=macOS,variant=Mac Catalyst', '-parallel-testing-enabled', 'NO',
                   '-maximum-concurrent-test-simulator-destinations', '1', '-collect-test-diagnostics', 'never',
                   '-derivedDataPath', str(root / 'DerivedData'),
                   '-resultBundlePath', str(bundle), 'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGNING_REQUIRED=YES', 'CODE_SIGN_IDENTITY=-',
                   'DEVELOPMENT_TEAM=', 'PROVISIONING_PROFILE_SPECIFIER=',
                   'IPHONEOS_DEPLOYMENT_TARGET=15.0', 'SUPPORTS_MACCATALYST=YES']
        command += ['-only-testing:TelnyxRTCTests/CallingCallKitAudioSessionTests/' + test for test in selectors]
        code = run(command, name, 1800, allow_test_failure=bool(expected_failures))
        verify_local_signatures(name)
        summary = json.loads(read(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(bundle)]))
        (evidence / (name + '-summary.json')).write_text(json.dumps(summary, indent=2) + '\n')
        log = (evidence / (name + '.log')).read_text(errors='replace')
        matches = re.findall(r"Test Case '[^\n]*\b(test\w+)[^\n]*' (passed|failed)", log)
        outcomes = dict(matches)
        proof = {'selectors': selectors, 'returnCode': code, 'summary': summary, 'testOutcomes': outcomes, 'resultBundle': str(bundle)}
        report[name] = proof
        save()
        if len(matches) != len(selectors) or set(outcomes) != set(selectors):
            raise RuntimeError(name + ' did not execute exactly the selected tests')
        observed_failures = {test for test, result in outcomes.items() if result == 'failed'}
        if observed_failures != set(expected_failures):
            raise RuntimeError(name + ' failure identities do not match the expected regression')
        if summary.get('failedTests') != len(expected_failures) or summary.get('passedTests') != len(selectors) - len(expected_failures):
            raise RuntimeError(name + ' result counts differ from exact expected cases')
        if summary.get('skippedTests', 0) or summary.get('expectedFailures', 0):
            raise RuntimeError(name + ' skipped or expected-failure cases are not permitted')
        if expected_failures and code == 0:
            raise RuntimeError('Baseline unexpectedly returned success')
        if not expected_failures and code != 0:
            raise RuntimeError('Corrected tests returned failure')

    try:
        previous = json.loads(args.previous_settled_receipt.read_text())
        if previous.get('commit') != '19c5abf6836a65d94eef83c0fd364d40c25f2dc3' or not previous.get('cleanupVerified') or not previous.get('temporaryRootRemoved'):
            raise RuntimeError('Previous immutable SDK validation has not completely settled')
        previous_root = Path(previous['temporaryRoot'])
        if previous_root.exists():
            raise RuntimeError('Previous temporary source unexpectedly remains')
        previous_groups = {entry['pgid'] for entry in previous.get('children', [])}
        if any(row['pgid'] in previous_groups for row in process_rows()):
            raise RuntimeError('Previous validation process group remains')
        report['previousSettledReceipt'] = str(args.previous_settled_receipt)
        report['previousReceiptSha256'] = digest(args.previous_settled_receipt.read_bytes())
        report['validationScope'] = 'Actual M124 engine configuration entry point with deliberate stop immediately after real configuration, before hardware input checks. Both OS activation selectors intercepted. No peer, audio unit, device, call, socket or playback. Inactive actual configuration; no synthetic hardware readback. Tests only, runtime source remains19c5. Catalyst local ad hoc signatures only.'
        if read(['git', 'rev-parse', COMMIT], REPOSITORY).strip() != COMMIT:
            raise RuntimeError('Pinned SDK commit unavailable')
        paths = ['TelnyxRTC', 'TelnyxRTCTests', 'TelnyxRTC.xcodeproj', 'Config.xcconfig', 'Config.xcconfig.example', 'TelnyxRTC.podspec', 'README.md', 'LICENSE']
        archive = subprocess.check_output(['git', 'archive', COMMIT] + paths, cwd=REPOSITORY, timeout=40)
        with tarfile.open(fileobj=io.BytesIO(archive)) as tree:
            tree.extractall(source, filter='data')
        resolver_path = 'TelnyxWebRTCDemo/PushCallUUIDResolver.swift'
        resolver = subprocess.check_output(['git', 'show', COMMIT + ':' + resolver_path], cwd=REPOSITORY, timeout=30)
        resolver_file = source / resolver_path
        resolver_file.parent.mkdir(exist_ok=True)
        resolver_file.write_bytes(resolver)
        report['additionalTestInputHashes'] = {resolver_path: digest(resolver)}
        project = (source / 'TelnyxRTC.xcodeproj/project.pbxproj').read_text()
        if 'TEST_HOST =' in project or 'BUNDLE_LOADER =' in project:
            raise RuntimeError('Unexpected app-hosted test target')
        scheme_path = source / 'TelnyxRTC.xcodeproj/xcshareddata/xcschemes/TelnyxRTCTests.xcscheme'
        scheme = ET.fromstring(scheme_path.read_text())
        build_refs = scheme.findall('./BuildAction/BuildActionEntries/BuildActionEntry/BuildableReference')
        test_refs = scheme.findall('./TestAction/Testables/TestableReference/BuildableReference')
        if [item.attrib.get('BlueprintName') for item in build_refs] != ['TelnyxRTC']:
            raise RuntimeError('Scheme builds an unexpected application')
        if [item.attrib.get('BlueprintName') for item in test_refs] != ['TelnyxRTCTests']:
            raise RuntimeError('Scheme includes unexpected test targets')
        if scheme.findall('.//BuildableProductRunnable'):
            raise RuntimeError('Scheme contains application runnable')
        report['testHostProof'] = {'projectSha256': digest(project.encode()), 'schemeSha256': digest(scheme_path.read_bytes()),
            'testHostOrBundleLoaderPresent': False, 'builtProduct': 'TelnyxRTC.framework', 'testProduct': 'TelnyxRTCTests.xctest',
            'productApplicationLaunch': False, 'simulatorOperations': False}
        overlay = REPOSITORY / 'TelnyxRTCTests/WebRTC/CallingCallKitAudioSessionTests.swift'
        (source / 'TelnyxRTCTests/WebRTC/CallingCallKitAudioSessionTests.swift').write_bytes(overlay.read_bytes())
        report['testOnlyOverlaySha256'] = digest(overlay.read_bytes())
        verify_source('corrected')
        test_source = (source / 'TelnyxRTCTests/WebRTC/CallingCallKitAudioSessionTests.swift').read_text()
        if re.findall(r'    func (test\w+)\(', test_source) != CASES:
            raise RuntimeError('Exact selected test cases changed')
        for forbidden in ['Peer(', '.connect(', '.newCall(', '.answer(', '.requestRecordPermission(']:
            if forbidden in test_source:
                raise RuntimeError('Selected tests may create media or network activity: ' + forbidden)
        if 'setActive:error:' not in test_source or 'setActive:withOptions:error:' not in test_source:
            raise RuntimeError('Both actual activation selectors must be intercepted')
        if test_source.index('OperatingSystemAudioActivationRecorder(session: session)') > test_source.index('client = TxClient()'):
            raise RuntimeError('Activation interception must precede SDK client initialization')
        native_cleanup = STATE / 'iphone91-apple-agreement-blocker-and-postflight-20261029.json'
        native = json.loads(native_cleanup.read_text())
        if not all(native.get(k) for k in ['nativeWorkerCleanupVerified','ownedProcessesAbsent','temporaryCheckoutAbsent']):
            raise RuntimeError('Previous native worker cleanup is incomplete')
        report['previousNativeCleanupReceipt'] = str(native_cleanup)
        report['previousNativeCleanupSha256'] = digest(native_cleanup.read_bytes())
        ruby = """require 'xcodeproj'
p = Xcodeproj::Project.open('TelnyxRTC.xcodeproj')
t = p.targets.find { |item| item.name == 'TelnyxRTCTests' }
t.source_build_phase.files.to_a.each { |f| t.source_build_phase.remove_build_file(f) }
f = p.main_group.new_file('TelnyxRTCTests/WebRTC/CallingCallKitAudioSessionTests.swift')
t.source_build_phase.add_file_reference(f)
p.save
"""
        project_adapter = root / 'select-tests.rb'
        project_adapter.write_text(ruby)
        run(['/usr/bin/env', 'GEM_HOME=/opt/homebrew/Cellar/cocoapods/1.17.0/libexec', '/opt/homebrew/opt/ruby/bin/ruby', str(project_adapter)], 'select-exact-tests', 60)
        report['testProjectAdapterSha256'] = digest(ruby.encode())
        report['xcode'] = read(['xcodebuild', '-version']).strip()
        if report['xcode'] != 'Xcode 27.1\nBuild version 27A9275':
            raise RuntimeError('Reviewed Xcode identity changed')
        if digest(PODFILE.encode()) != '657ae535f13124c06f863b8cda131e241c52d1abf98520558b8b2987dbe99b27':
            raise RuntimeError('Dependency contract changed')
        (source / 'Podfile').write_text(PODFILE)
        (evidence / 'Podfile').write_text(PODFILE)
        run(['/opt/homebrew/bin/pod', 'install', '--no-repo-update'], 'dependencies', 600)
        lock = (source / 'Podfile.lock').read_bytes()
        required = ['  - Starscream (4.0.8)', '  - WebRTC-lib (124.0.0)', '  Starscream: 19b5533ddb925208db698f0ac508a100b884a1b9',
                    '  WebRTC-lib: 4afd321517808deb428933ab7ffeced4fc4fe745', 'COCOAPODS: 1.17.0']
        if any(value not in lock.decode() for value in required) or 'Firebase' in lock.decode() or '139.0' in lock.decode():
            raise RuntimeError('Resolved dependency ABI changed')
        (evidence / 'Podfile.lock').write_bytes(lock)
        report['dependencyLockSha256'] = digest(lock)
        if report['dependencyLockSha256'] != previous.get('dependencyLockSha256'):
            raise RuntimeError('Catalyst dependency lock differs from settled simulator attempt')
        xcframeworks = list((source / 'Pods').glob('**/WebRTC.xcframework/Info.plist'))
        if len(xcframeworks) != 1:
            raise RuntimeError('Expected one exact WebRTC xcframework')
        xcframework = plistlib.loads(xcframeworks[0].read_bytes())
        slices = [item for item in xcframework['AvailableLibraries']
            if item.get('SupportedPlatform') == 'ios' and item.get('SupportedPlatformVariant') == 'maccatalyst'
            and 'arm64' in item.get('SupportedArchitectures', [])]
        if len(slices) != 1:
            raise RuntimeError('Pinned WebRTC lacks usable Apple Silicon Catalyst slice')
        report['webRTCCatalystSlice'] = slices[0]
        report['webRTCFrameworkInfoSha256'] = digest(xcframeworks[0].read_bytes())
        verify_source('corrected')
        baseline_client = subprocess.check_output(['git','show',BASELINE + ':TelnyxRTC/Telnyx/TxClient.swift'], cwd=REPOSITORY, timeout=30)
        corrected_client = (source / 'TelnyxRTC/Telnyx/TxClient.swift').read_bytes()
        (source / 'TelnyxRTC/Telnyx/TxClient.swift').write_bytes(baseline_client)
        verify_source('baseline')
        test_phase('baseline', BASELINE_FAILURES, BASELINE_FAILURES)
        (source / 'TelnyxRTC/Telnyx/TxClient.swift').write_bytes(corrected_client)
        verify_source('corrected')
        test_phase('corrected', CASES, [])
        verify_source('corrected')
        report['status'] = 'passed'
    except BaseException as error:
        report['status'] = 'failed'
        report['error'] = str(error)
    finally:
        cleanup_errors = []
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if active is not None and active.poll() is None:
            try:
                if os.getpgid(active.pid) == active.pid:
                    os.killpg(active.pid, signal.SIGTERM)
                    try:
                        active.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        os.killpg(active.pid, signal.SIGKILL)
                        active.wait(timeout=15)
            except ProcessLookupError:
                pass
            except BaseException as error:
                cleanup_errors.append('active process: ' + str(error))
        groups = {entry['pgid'] for entry in report['children']}
        try:
            owned = [row for row in process_rows() if row['pgid'] in groups]
            for group in {row['pgid'] for row in owned}:
                try:
                    os.killpg(group, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            if owned:
                time.sleep(2)
            for group in {row['pgid'] for row in process_rows() if row['pgid'] in groups}:
                try:
                    os.killpg(group, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            aliases = [str(root), str(root).replace('/private/tmp/', '/tmp/')]
            report['remainingOwnedProcesses'] = [row for row in process_rows()
                if any(alias in row['command'] for alias in aliases) or row['pgid'] in groups]
            report['cleanupVerified'] = not report['remainingOwnedProcesses']
            if report['cleanupVerified']:
                shutil.rmtree(root)
                report['temporaryRootRemoved'] = not root.exists()
        except BaseException as error:
            cleanup_errors.append('postflight: ' + str(error))
        report['cleanupErrors'] = cleanup_errors
        if cleanup_errors:
            report['cleanupVerified'] = False
        report['finishedAt'] = time.time()
        save()
        print(json.dumps({'status': report['status'], 'receipt': str(evidence / 'receipt.json'),
                          'cleanupVerified': report.get('cleanupVerified', False), 'temporaryRootRemoved': report.get('temporaryRootRemoved', False)}), flush=True)
    return 0 if report['status'] == 'passed' and report.get('cleanupVerified') and report.get('temporaryRootRemoved') else 1


if __name__ == '__main__':
    raise SystemExit(main())
