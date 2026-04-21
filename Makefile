.PHONY: build test format lint

# This package depends on UIKit (UIHostingController), so `swift build` on a
# macOS host cannot resolve `import UIKit`. Use xcodebuild against an iOS
# Simulator destination instead.

DESTINATION ?= 'platform=iOS Simulator,name=iPhone 17'

build:
	xcodebuild build -scheme SwiftUIEx -destination $(DESTINATION)

test:
	xcodebuild test -scheme SwiftUIEx -destination $(DESTINATION)

format:
	swift format --in-place --recursive Sources Tests

lint:
	swift format lint --strict --recursive Sources Tests
