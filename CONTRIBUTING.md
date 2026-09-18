# Contributing

The most useful thing a stranger can do is read the security path and say
what is wrong with it. Start with `docs/SDS.md`, then `Seal/Crypto/`,
`Seal/Estate/EstateKeys.swift`, `Seal/Estate/ReleaseMachine.swift` and
`tools/verify_capsule.py`.

## Before you open a pull request

Run the same four checks that run in continuous integration. They need
Python 3 and one library, and they need no Mac, no Apple account and no
phone:

```
pip install cryptography
python3 tools/shamir_vectors.py
python3 tools/make_test_capsule.py > /tmp/capsule.json
python3 tools/verify_capsule.py /tmp/capsule.json
python3 tools/check_imports.py
python3 tools/check_house_rules.py
```

The app's own tests live in `Seal/SelfTest/` and run on every DEBUG launch,
because a passkey needs a real app to live in. A failed test blacks the
screen on purpose. `docs/TESTS.md` lists all of them by name.

On a Mac you can also run the parts that need no app, straight from the same
source files and the same suites:

```
sh tools/run_core_tests.sh
```

Today that is the key split and the release countdown. A file joins the list
in that script only when it compiles with no user interface, no network and
no keychain behind it.

## House rules

- **No dependencies.** No package manager, no vendored code, no analytics,
  no crash reporter. `tools/check_imports.py` enforces it.
- **The word is "key holder"**, never "custodian", in anything a person
  reads. Code names keep the old word.
- **No em dashes**, anywhere.
- **Plain words.** Every sentence in the app should read aloud to a parent
  over sixty. One idea per sentence, the plain thing first.
- **Never promise more than `docs/PRODUCT.md` section 7.** Seal cannot know
  somebody died. It knows they went quiet.
- **Every new Swift file carries the Mozilla Public License notice.**
- Read `docs/GOTCHAS.md` before debugging anything. It is the list of what
  already went wrong.

## Security findings

Not a public issue. See [SECURITY.md](SECURITY.md).
