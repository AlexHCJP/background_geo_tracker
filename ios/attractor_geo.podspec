#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint attractor_geo.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'attractor_geo'
  s.version          = '0.2.0'
  s.summary          = 'Native continuous geolocation tracking with upload.'
  s.description      = <<-DESC
Records a continuous route track and uploads it in batches, without depending
on a live Dart isolate.
                       DESC
  s.homepage         = 'https://attractor.school'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Attractor School' => 'dev@attractor.school' }
  s.source           = { :path => '.' }
  s.source_files = 'attractor_geo/Sources/attractor_geo/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.library = 'sqlite3'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # Required, not optional: this plugin collects precise location and reads
  # UserDefaults, which is a required-reason API. Apple rejects submissions
  # where an SDK touching those has no privacy manifest.
  s.resource_bundles = {'attractor_geo_privacy' => ['attractor_geo/Sources/attractor_geo/PrivacyInfo.xcprivacy']}
end
