require 'fileutils'
require 'digest'
require 'json'
require 'optparse'
require 'xcodeproj'

sdk_root = File.expand_path('../..', __dir__)
destination = File.expand_path(ARGV.shift || abort('Supply an owned project directory'))
extra_sources = []
extra_tests = []
fixtures = []
snapshot_source = nil
OptionParser.new do |options|
  options.on('--source PATH') { |path| extra_sources << File.expand_path(path) }
  options.on('--test PATH') { |path| extra_tests << File.expand_path(path) }
  options.on('--fixture PATH') { |path| fixtures << File.expand_path(path) }
  options.on('--snapshot-source PATH') { |path| snapshot_source = File.expand_path(path) }
end.parse!
abort('Unexpected generator arguments') unless ARGV.empty?
(extra_sources + extra_tests + fixtures + [snapshot_source].compact).each do |path|
  abort("Missing harness input: #{path}") unless File.file?(path)
end
FileUtils.mkdir_p(destination)
if snapshot_source
  original = File.binread(snapshot_source)
  start_index = original.index(/^struct TelnyxPstnNativeQualitySnapshot \{/)
  end_index = original.index(/^struct TelnyxPstnNativeAudioState \{/)
  abort('Cannot identify the exact production quality snapshot declaration') unless start_index && end_index && end_index > start_index
  declaration = original[start_index...end_index]
  extracted_path = File.join(destination, 'TelnyxPstnNativeQualitySnapshot.swift')
  File.binwrite(extracted_path, "import Foundation\nimport CoreFoundation\n\n" + declaration)
  extra_tests << extracted_path
  revision = IO.popen(['git', '-C', File.dirname(snapshot_source), 'rev-parse', 'HEAD'], &:read).strip
  provenance = {
    sourcePath: snapshot_source,
    sourceCommit: revision,
    sourceSHA256: Digest::SHA256.hexdigest(original),
    declarationSHA256: Digest::SHA256.hexdigest(declaration),
    extractedSHA256: Digest::SHA256.file(extracted_path).hexdigest,
    extraction: 'Exact declaration with Foundation and CoreFoundation imports; no implementation rewritten'
  }
  provenance_path = File.join(destination, 'NativeSnapshotSourceProvenance.json')
  File.write(provenance_path, JSON.pretty_generate(provenance) + "\n")
  fixtures << provenance_path
end
project = Xcodeproj::Project.new(File.join(destination, 'CallingAudioRegression.xcodeproj'))
framework = project.new_target(:framework, 'TelnyxRTC', :ios, '14.0')
host = project.new_target(:application, 'CallingAudioHost', :ios, '14.0')
tests = project.new_target(:unit_test_bundle, 'CallingAudioOwnershipTests', :ios, '14.0')

project.targets.each do |target|
  target.build_configurations.each do |configuration|
    configuration.build_settings.merge!({
      'SWIFT_VERSION' => '5.0',
      'IPHONEOS_DEPLOYMENT_TARGET' => '14.0',
      'GENERATE_INFOPLIST_FILE' => 'YES',
      'PRODUCT_BUNDLE_IDENTIFIER' => "com.upgradeos.regression.#{target.name}",
      'CODE_SIGNING_ALLOWED' => 'NO',
      'ENABLE_TESTABILITY' => 'YES',
      'CLANG_ENABLE_OBJC_ARC' => 'YES',
      'SWIFT_OPTIMIZATION_LEVEL' => '-Onone',
      'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks'],
    })
  end
end

source_group = project.main_group.new_group('SDK source')
(Dir.glob(File.join(sdk_root, 'TelnyxRTC/**/*.swift')) + extra_sources).uniq.sort.each do |path|
  next if path.include?('/Exclude/')
  framework.source_build_phase.add_file_reference(source_group.new_file(path))
end
test_files = Dir.glob(File.join(sdk_root, 'TelnyxRTCTests/WebRTC/Calling*Tests.swift')) + extra_tests
test_files.uniq.sort.each do |path|
  tests.source_build_phase.add_file_reference(project.main_group.new_file(path))
end
support_directory = File.join(sdk_root, 'TelnyxRTCTests/WebRTC/Support')
Dir.glob(File.join(support_directory, '*.{m,swift}')).sort.each do |path|
  tests.source_build_phase.add_file_reference(project.main_group.new_file(path))
end
Dir.glob(File.join(support_directory, '*.h')).sort.each do |path|
  project.main_group.new_file(path)
end
fixtures.each do |path|
  tests.resources_build_phase.add_file_reference(project.main_group.new_file(path))
end

host_source = File.join(destination, 'CallingAudioHost.swift')
File.write(host_source, <<~SWIFT)
  import UIKit
  @main final class CallingAudioHost: UIResponder, UIApplicationDelegate {
      var window: UIWindow?
      func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
          let window = UIWindow(frame: UIScreen.main.bounds)
          window.rootViewController = UIViewController()
          window.makeKeyAndVisible()
          self.window = window
          return true
      }
  }
SWIFT
host.source_build_phase.add_file_reference(project.main_group.new_file(host_source))
host.build_configurations.each do |configuration|
  configuration.build_settings['INFOPLIST_KEY_NSMicrophoneUsageDescription'] = 'Native audio regression testing.'
end
host.add_dependency(framework)
host.frameworks_build_phase.add_file_reference(framework.product_reference)
embed = host.new_copy_files_build_phase('Embed SDK')
embed.dst_subfolder_spec = '10'
embed.add_file_reference(framework.product_reference).settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
tests.add_dependency(host)
tests.add_dependency(framework)
tests.frameworks_build_phase.add_file_reference(framework.product_reference)
tests.build_configurations.each do |configuration|
  configuration.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/CallingAudioHost.app/CallingAudioHost'
  configuration.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
  configuration.build_settings['SWIFT_OBJC_BRIDGING_HEADER'] = File.join(support_directory, 'CallingAudioTests-Bridging-Header.h')
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(host)
scheme.add_build_target(tests)
scheme.add_test_target(tests)
scheme.set_launch_target(host)
scheme.save_as(project.path, 'CallingAudioOwnershipTests', true)

File.write(File.join(destination, 'Podfile'), <<~RUBY)
  source 'https://cdn.cocoapods.org/'
  platform :ios, '14.0'
  project 'CallingAudioRegression'
  use_frameworks!
  install! 'cocoapods', :disable_input_output_paths => true
  abstract_target 'CallingAudioDependencies' do
    pod 'WebRTC-lib', '124.0.0'
    pod 'Starscream', '4.0.8'
    target 'TelnyxRTC'
    target 'CallingAudioHost'
    target 'CallingAudioOwnershipTests'
  end
RUBY
puts destination
