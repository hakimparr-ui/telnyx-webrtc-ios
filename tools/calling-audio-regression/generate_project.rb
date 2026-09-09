require 'fileutils'
require 'xcodeproj'

sdk_root = File.expand_path('../..', __dir__)
destination = File.expand_path(ARGV.fetch(0))
FileUtils.mkdir_p(destination)
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
      'SWIFT_OPTIMIZATION_LEVEL' => '-Onone',
      'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks'],
    })
  end
end

source_group = project.main_group.new_group('SDK source')
Dir.glob(File.join(sdk_root, 'TelnyxRTC/**/*.swift')).sort.each do |path|
  next if path.include?('/Exclude/')
  framework.source_build_phase.add_file_reference(source_group.new_file(path))
end
test_file = File.join(sdk_root, 'TelnyxRTCTests/WebRTC/CallingAudioOwnershipTests.swift')
tests.source_build_phase.add_file_reference(project.main_group.new_file(test_file))

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
