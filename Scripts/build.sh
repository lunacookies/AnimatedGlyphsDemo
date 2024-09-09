#!/bin/sh

set -e

clang-format -i Source/*.h Source/*.m Source/*.metal

rm -rf "Build"

mkdir -p "Build/AnimatedGlyphsDemo.app/Contents/MacOS"
mkdir -p "Build/AnimatedGlyphsDemo.app/Contents/Resources"

cp "Data/AnimatedGlyphsDemo-Info.plist" "Build/AnimatedGlyphsDemo.app/Contents/Info.plist"
plutil -convert binary1 "Build/AnimatedGlyphsDemo.app/Contents/Info.plist"

clang \
	-o "Build/AnimatedGlyphsDemo.app/Contents/MacOS/AnimatedGlyphsDemo" \
	-fmodules -fobjc-arc \
	-g3 \
	-fsanitize=undefined \
	-W \
	-Wall \
	-Wextra \
	-Wpedantic \
	-Wconversion \
	-Wimplicit-fallthrough \
	-Wmissing-prototypes \
	-Wshadow \
	-Wstrict-prototypes \
	"Source/EntryPoint.m"

xcrun metal \
	-o "Build/AnimatedGlyphsDemo.app/Contents/Resources/default.metallib" \
	-gline-tables-only -frecord-sources \
	"Source/Shaders.metal"
