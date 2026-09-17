#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Proves the "no third party code" claim, on every push.

Seal has no package manager, no vendored source and no analytics. That is
easy to say and easy to break by accident, so this walks every Swift file
and fails if it imports anything that is not an Apple framework, or if a
dependency manifest appears in the tree.

    python3 tools/check_imports.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Apple frameworks only. Adding a line here is a decision, not a formality:
# it is the moment Seal would stop being dependency free.
ALLOWED = {
    "AVFoundation", "AVKit", "AppIntents", "AuthenticationServices", "CloudKit",
    "CoreImage", "CoreImage.CIFilterBuiltins", "CryptoKit", "Foundation",
    "FoundationModels", "LocalAuthentication", "Photos", "Security", "Speech",
    "StoreKit", "SwiftUI", "UIKit", "UniformTypeIdentifiers", "UserNotifications",
    "Vision", "VisionKit", "WidgetKit", "os", "OSLog", "Combine", "Charts",
    "PDFKit", "QuickLook", "SafariServices", "StoreKitTest", "XCTest",
}

# Files that would mean a package manager had arrived.
MANIFESTS = [
    "Podfile", "Cartfile", "Package.resolved",
    os.path.join("Seal.xcodeproj", "project.xcworkspace", "xcshareddata", "swiftpm"),
]

IMPORT = re.compile(r"^\s*(?:@preconcurrency\s+|@_implementationOnly\s+)?import\s+([A-Za-z_][A-Za-z0-9_.]*)")


def swift_files():
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in {".git", "DerivedData", "build"}]
        for name in files:
            if name.endswith(".swift"):
                yield os.path.join(base, name)


def main():
    problems = []
    seen = set()
    for path in swift_files():
        with open(path, encoding="utf-8") as handle:
            for number, line in enumerate(handle, 1):
                match = IMPORT.match(line)
                if not match:
                    continue
                module = match.group(1)
                seen.add(module)
                if module not in ALLOWED:
                    problems.append(f"{os.path.relpath(path, ROOT)}:{number}: imports {module}")

    for manifest in MANIFESTS:
        if os.path.exists(os.path.join(ROOT, manifest)):
            problems.append(f"{manifest} exists, so this project now has dependencies")

    print(f"checked every Swift file, {len(seen)} distinct imports, all Apple frameworks"
          if not problems else "third party code found")
    for line in problems:
        print("  FAIL " + line)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
