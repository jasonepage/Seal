#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""The house rules, checked by a machine instead of by memory.

    python3 tools/check_house_rules.py

Four rules, each one something that has gone wrong before:

1. No em dash anywhere in the app, the site or the current docs. It keeps
   sneaking into copy and it is not the voice of this app.
2. No "custodian" in anything a person reads. The word in the app is
   "key holder". Code names keep the old word and are ignored, and so is
   anything inside a string interpolation, because that is a variable name.
3. No private key anywhere in the tree. A stray ".DS_Store" is a note,
   because .gitignore already keeps it out of the repository.
4. Nothing in the app may write to a hard coded price. The price comes
   from the App Store.

docs/archive holds retired documents and is skipped.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP_DIRS = {".git", "DerivedData", "build", "archive", "Wordlists", "Claude outputs"}
TEXT_EXTENSIONS = {".swift", ".html", ".css", ".md", ".py", ".txt", ".json", ".toml", ".yml", ".yaml"}

EM_DASH = "—"
PRICE = re.compile(r"\$\s*\d")


def visible_text(line):
    """The words a person would read: the contents of string literals,
    with every \\(interpolation) removed, because those are code names.
    Written as a small scanner rather than a regular expression: an
    interpolation can hold its own quotes and its own parentheses, and
    that is exactly where the word "custodian" hides in this codebase."""
    out = []
    i, n = 0, len(line)
    in_string = False
    while i < n:
        c = line[i]
        if not in_string:
            if c == '"':
                in_string = True
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            if line[i + 1] == "(":       # an interpolation: skip it whole
                depth, i = 0, i + 1
                while i < n:
                    if line[i] == "(":
                        depth += 1
                    elif line[i] == ")":
                        depth -= 1
                        if depth == 0:
                            i += 1
                            break
                    elif line[i] == '"':  # a string inside the interpolation
                        i += 1
                        while i < n and line[i] != '"':
                            i += 2 if line[i] == "\\" else 1
                    i += 1
                continue
            i += 2
            continue
        if c == '"':
            in_string = False
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def files():
    for base, dirs, names in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in names:
            if os.path.splitext(name)[1] in TEXT_EXTENSIONS:
                yield os.path.join(base, name)


def main():
    problems = []
    checked = 0
    for path in files():
        rel = os.path.relpath(path, ROOT)
        # This file names the rules, so it is allowed to spell them out.
        itself = rel == os.path.join("tools", "check_house_rules.py")
        checked += 1
        with open(path, encoding="utf-8", errors="replace") as handle:
            for number, line in enumerate(handle, 1):
                if not itself and EM_DASH in line:
                    problems.append(f"{rel}:{number}: em dash")
                if not itself and ("BEGIN PRIVATE KEY" in line or "BEGIN EC PRIVATE KEY" in line):
                    problems.append(f"{rel}:{number}: a private key is in the tree")
                # Only what a person reads: the screens. Engine errors,
                # log lines and the self-tests keep the old code word.
                if rel.startswith(os.path.join("Seal", "Views")) and not itself:
                    naked = visible_text(line)
                    if "custodian" in naked.lower():
                        problems.append(f"{rel}:{number}: says custodian to a person, use key holder")
                    if PRICE.search(naked):
                        problems.append(f"{rel}:{number}: a price is written into the code")

    # .DS_Store is a note, not a failure: .gitignore already keeps it out of
    # the repository, so one sitting in a working copy is Finder's doing and
    # not something a checkout in continuous integration would ever see.
    strays = []
    for base, dirs, names in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in {".git"}]
        for name in names:
            if name == ".DS_Store":
                strays.append(os.path.relpath(os.path.join(base, name), ROOT))

    for stray in strays:
        print(f"  note {stray} is in your working copy, ignored by git")
    print(f"house rules: {checked} files checked" if not problems else "house rules broken")
    for line in problems:
        print("  FAIL " + line)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
