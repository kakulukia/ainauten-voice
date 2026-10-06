#!/usr/bin/env python3
"""Retained, isolated Mach-O fixtures for the missing-library launch regression."""
import argparse
import datetime
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
from unittest.mock import patch
from app_bundle import verify_runtime, replace_local_app
from package_dmg import create_dmg

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path)
args = parser.parse_args()
out = args.output or root / 'artifacts/receipts' / ('app-bundle-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
out = out.resolve()
out.mkdir(parents=True, exist_ok=False)
app = out / 'valid/AInauten Voice.app'
macos = app / 'Contents/MacOS'
frameworks = app / 'Contents/Frameworks'
macos.mkdir(parents=True)
frameworks.mkdir()
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'Fixture', 'CFBundleIdentifier': 'com.mediapublishing.VoiceWispr',
    'CFBundleShortVersionString': '0.0.0'}))
sources = {'leaf.c': 'int leaf(void) { return 0; }\n',
           'library.c': 'extern int leaf(void); int fixture(void) { return leaf(); }\n',
           'main.c': 'extern int fixture(void); int main(void) { return fixture(); }\n'}
for name, text in sources.items():
    (out / name).write_text(text)
cc = ['xcrun', 'clang', '-arch', 'arm64', '-mmacosx-version-min=14.0']
subprocess.run(cc + ['-dynamiclib', str(out / 'leaf.c'), '-install_name', '@rpath/libleaf.dylib',
                    '-o', str(frameworks / 'libleaf.dylib')], check=True)
subprocess.run(cc + ['-dynamiclib', str(out / 'library.c'), '-L', str(frameworks), '-lleaf',
                    '-install_name', '@rpath/libfixture.dylib', '-o', str(frameworks / 'libfixture.dylib')], check=True)
subprocess.run(cc + [str(out / 'main.c'), '-L', str(frameworks), '-lfixture',
                    '-Wl,-rpath,@executable_path/../Frameworks', '-Wl,-headerpad_max_install_names',
                    '-o', str(macos / 'Fixture')], check=True)
assert verify_runtime(app) == 3
checks = ['bundled transitive dependencies resolve']
relocated = out / 'moved directory/AInauten Voice.app'
shutil.copytree(app, relocated, symlinks=True)
assert verify_runtime(relocated) == 3
checks.append('bundle relocation preserves relative library lookup')

def reject(label, mutate, expected):
    fixture = out / label / 'AInauten Voice.app'
    shutil.copytree(app, fixture, symlinks=True)
    mutate(fixture)
    try:
        verify_runtime(fixture)
    except ValueError as error:
        assert expected in str(error), error
    else:
        raise AssertionError(label + ' was accepted')
    checks.append(label + ' rejected')
    return fixture

bad = reject('missing-rpath', lambda a: subprocess.run(
    ['install_name_tool', '-delete_rpath', '@executable_path/../Frameworks', str(a / 'Contents/MacOS/Fixture')], check=True),
    '@rpath/libfixture.dylib')
reject('missing-transitive-library', lambda a: (a / 'Contents/Frameworks/libleaf.dylib').rename(
    a / 'Contents/Frameworks/libleaf.disabled'), '@rpath/libleaf.dylib')
reject('external-development-library', lambda a: subprocess.run(
    ['install_name_tool', '-change', '@rpath/libfixture.dylib', str(frameworks / 'libfixture.dylib'),
     str(a / 'Contents/MacOS/Fixture')], check=True), str(frameworks / 'libfixture.dylib'))
rejected_dmg = out / 'rejected-dmg'
try:
    create_dmg(bad, rejected_dmg)
except ValueError as error:
    assert '@rpath/libfixture.dylib' in str(error), error
else:
    raise AssertionError('DMG packaging accepted broken runtime')
assert not rejected_dmg.exists()
checks.append('DMG creation stops before producing an invalid installer')
def local_fixture(path, marker, local=True):
    shutil.copytree(app, path, symlinks=True)
    info_path = path / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["AInautenLocalBuild"] = local
    info["CFBundleExecutable"] = "VoiceWispr"
    (path / "Contents/MacOS/Fixture").rename(path / "Contents/MacOS/VoiceWispr")
    info_path.write_bytes(plistlib.dumps(info))
    (path / "marker").write_text(marker)
    return path


fixed = out / "local-fixed/AInauten Voice Dev.app"
fixed.parent.mkdir()
prepared = local_fixture(out / "local-first/prepared/AInauten Voice.app", "first")
replace_local_app(prepared, fixed)
assert (fixed / "marker").read_text() == "first" and not prepared.exists()
checks.append("first local bundle uses the fixed path")
prepared = local_fixture(out / "local-second/prepared/AInauten Voice.app", "second")
replace_local_app(prepared, fixed)
assert (fixed / "marker").read_text() == "second"
assert (prepared.parent / "previous.app/marker").read_text() == "first"
checks.append("next local bundle replaces the same fixed path")


def reject_local(label, target, prepared, **kwargs):
    try:
        replace_local_app(prepared, target, **kwargs)
    except ValueError:
        assert prepared.is_dir()
    else:
        raise AssertionError(label + " was accepted")
    checks.append(label + " rejected")


prepared = local_fixture(
    out / "local-protection/prepared/AInauten Voice.app", "candidate"
)
public = local_fixture(
    out / "local-protection/public/AInauten Voice.app", "public", local=False
)
reject_local("public app replacement", public, prepared)
assert (public / "marker").read_text() == "public"
unexpected = local_fixture(out / "local-protection/unexpected/AInauten Voice.app", "unexpected")
info_path = unexpected / "Contents/Info.plist"
info = plistlib.loads(info_path.read_bytes())
info["CFBundleExecutable"] = "../../outside"
info_path.write_bytes(plistlib.dumps(info))
reject_local("unexpected executable path", unexpected, prepared)
assert (unexpected / "marker").read_text() == "unexpected"
alias = out / "local-protection/alias.app"
alias.symlink_to(public)
reject_local("unexpected destination symlink", alias, prepared)
assert alias.resolve() == public
original_run = subprocess.run


def running_fixture(command, **kwargs):
    if command[0] == "lsof":
        return subprocess.CompletedProcess(command, 0, b"123\n", b"")
    return original_run(command, **kwargs)


with patch("app_bundle.subprocess.run", side_effect=running_fixture):
    reject_local("running local app replacement", fixed, prepared)
assert (fixed / "marker").read_text() == "second"
with patch(
    "app_bundle.verify_runtime", side_effect=ValueError("injected verification failure")
):
    reject_local("failed local bundle verification", fixed, prepared)
assert (fixed / "marker").read_text() == "second"
assert (prepared / "marker").read_text() == "candidate"
checks.append("failed replacement restores both bundles")

legacy_source = local_fixture(out / "local-legacy/source/AInauten Voice.app", "legacy")
legacy_link = out / "local-legacy/AInauten Voice.app"
legacy_link.symlink_to(legacy_source)
prepared = local_fixture(out / "local-legacy/prepared/AInauten Voice.app", "stable")
replace_local_app(prepared, legacy_link, legacy_link=legacy_link)
assert not legacy_link.is_symlink() and legacy_source.is_dir()
assert (legacy_link / "marker").read_text() == "stable"
checks.append("legacy project link becomes a fixed bundle without deleting its source")
(out / 'receipt.json').write_text(json.dumps({'status': 'pass', 'checks': checks, 'fixture_apps_launched': False}, indent=2) + '\n')
print(f'BUNDLE REGRESSION PASS: {len(checks)} checks; receipt {out / "receipt.json"}')
