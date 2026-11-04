# Google ML Kit's on-device Persian handwriting recognizer, for the keyboard's handwriting pad
# (PersianSTTKeyboard/Handwriting.swift). Only build.yml and ink-eval.yml run `pod install`;
# the other workflows build the project without it, and the pad then says it is not in that build.
# ML Kit ships device (arm64) and Intel simulator (x86_64) code only.
platform :ios, '17.0'
project 'PersianSTT.xcodeproj'
install! 'cocoapods', :warn_for_unused_master_specs_repo => false
use_frameworks! :linkage => :static

# The app hosts the keyboard (CocoaPods asks for the host); it gets the recognizer itself only
# for the handwriting benchmark (launch argument -inkBenchmark).
target 'PersianSTT' do
  pod 'MLKitDigitalInkRecognition', '8.0.0' if ENV['INK_IN_APP'] == '1'
end

target 'PersianSTTKeyboard' do
  pod 'MLKitDigitalInkRecognition', '8.0.0'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
    end
  end
end
