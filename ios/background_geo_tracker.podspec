#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint background_geo_tracker.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'background_geo_tracker'
  s.version          = '0.3.0'
  s.summary          = 'Native continuous geolocation tracking with upload.'
  s.description      = <<-DESC
Records a continuous route track and uploads it in batches, without depending
on a live Dart isolate.
                       DESC
  s.homepage         = 'https://attractor.school'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Attractor School' => 'dev@attractor.school' }
  s.source           = { :path => '.' }
  s.source_files = 'background_geo_tracker/Sources/background_geo_tracker/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.library = 'sqlite3'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # Required, not optional: this plugin collects precise location and reads
  # UserDefaults, which is a required-reason API. Apple rejects submissions
  # where an SDK touching those has no privacy manifest.
  s.resource_bundles = {'background_geo_tracker_privacy' => ['background_geo_tracker/Sources/background_geo_tracker/PrivacyInfo.xcprivacy']}
end
