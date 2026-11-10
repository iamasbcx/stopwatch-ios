# Stopwatch iOS

A SwiftUI stopwatch shell for GitHub and Codemagic. The first screen is an ordinary countdown stopwatch. Enter a number and tap `Start` to count down. The reserved value `5201314` opens the private lap workspace.

## Features

- Stopwatch countdown with pause and reset.
- Local memory for the last lap tag and editable result text.
- A result `TextEditor` with native selection, editing, copy, paste, and share support.
- Lap and split history with cursor pagination, automatic refresh, metrics, details, and export.
- Separate split and time settings sheets.
- `URLSession` networking and explicit errors when native secure signing is not linked.

## Layout

- `Sources/StopwatchApp.swift`: app entry point.
- `Sources/StopwatchView.swift`: public stopwatch gate.
- `Sources/LapView.swift`: private lap workspace and editable result area.
- `Sources/StopwatchEngine.swift`: network and response conversion.
- `Sources/StopwatchState.swift`: async state, pagination, local memory, and auto lap.
- `Sources/LapDetailsView.swift`, `Sources/SplitView.swift`, `Sources/TimeSettingsView.swift`: supporting sheets.
- `StopwatchIOS.xcodeproj`: standard Xcode project.
- `codemagic.yaml`: unsigned archive workflow.

## Codemagic

Push this directory to GitHub and select it in Codemagic. The workflow builds an unsigned archive with `xcodebuild` on `mac_mini_m2`. Configure Apple signing credentials in Codemagic when an installable IPA is required.

This workspace runs on Windows and does not include Xcode or the iOS SDK, so local iOS compilation is not claimed here. Codemagic performs the real macOS build.

## Secure native module

The original Windows C++ project uses Windows `.lib` files and OpenSSL/libcurl/secp256k1. Those binaries cannot be linked into iOS. The Swift shell keeps secure split actions explicit and refuses to fake a signature or broadcast. A production build should add an arm64 Objective-C++ native module and wire the original signing routines only after rebuilding their dependencies for device and simulator.

