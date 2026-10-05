#!/usr/bin/env python3
"""Build a signed app and DMG without deleting existing artifacts or keys."""

import argparse, base64, datetime, os, pathlib, plistlib, re, shutil, subprocess
from package_dmg import create_dmg
from app_bundle import verify_runtime

root = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument("--debug", action="store_true")
p.add_argument("--install", action="store_true")
p.add_argument(
    "--sdk",
    type=pathlib.Path,
    help="Explicit compatible macOS SDK; leaves the system default unchanged",
)
p.add_argument(
    "--build-system",
    choices=["native", "swiftbuild"],
    help="Swift build engine override for compatible CLT packaging",
)
p.add_argument(
    "--adhoc",
    action="store_true",
    help="Local test build only: allow ad-hoc signing without the stable identity",
)
p.add_argument(
    "--sign-identity",
    help="SHA-1 of an existing code-signing identity in the macOS keychain",
)
p.add_argument(
    "--install-directory",
    type=pathlib.Path,
    help="Existing installation directory; defaults to the system installation when writable",
)
p.add_argument(
    "--local",
    action="store_true",
    help="Prepare a project-local app with updates disabled, without an installer",
)
p.add_argument(
    "--uv",
    type=pathlib.Path,
    help="Existing uv 0.12.5 executable for the optional installer",
)
args = p.parse_args()
if args.local and args.install:
    p.error("--local cannot be combined with --install")
if args.sdk:
    os.environ["SDKROOT"] = str(args.sdk)
# Public update key only. Generating a new private signing identity is a separate
# explicitly approved action; an absent key leaves the runtime updater inactive.
public_key_file = root / "Resources/update-public-key.txt"
public_key = (
    public_key_file.read_text().strip()
    if public_key_file.exists() and not args.local
    else None
)
if public_key is not None:
    try:
        decoded_key = base64.b64decode(public_key, validate=True)
    except ValueError:
        p.error("invalid public update key")
    if len(decoded_key) != 32 or not any(decoded_key):
        p.error("invalid public update key")
# Only a public fingerprint is stored here. The signing key stays in Keychain.
identity_file = root / ".local" / "signing-identity"
identity = args.sign_identity or (
    identity_file.read_text().strip() if identity_file.exists() else "-"
)
# Ad-hoc bundles lose macOS permissions on every update; never produce them silently.
if identity == "-" and not args.adhoc:
    p.error(
        "stable signing identity missing (.local/signing-identity); pass --adhoc only for a local test build"
    )
if identity != "-":
    if not re.fullmatch(r"[0-9a-fA-F]{40}", identity):
        p.error("signing identity must be a 40-character certificate fingerprint")
    identities = subprocess.check_output(
        ["security", "find-identity", "-p", "codesigning"], text=True
    )
    if identity.upper() not in identities.upper():
        p.error("configured signing identity is unavailable; refusing ad-hoc fallback")


def run(*cmd):
    return subprocess.run(cmd, cwd=root, check=True)


# The internal development report must never be distributed in an app bundle.
user_report = root / "docs/user-verification-report.md"
report_text = user_report.read_text()
if not report_text.startswith("# AInauten Voice: Prüfbericht") or any(
    value in report_text
    for value in [
        "/Users/",
        "/home/",
        "PRIVATE KEY",
        "Administratorpasswort",
        "Voice Wispr",
    ]
):
    raise SystemExit(
        "The user verification report is missing or contains internal data"
    )
configuration = "debug" if args.debug else "release"
run("python3", "scripts/bootstrap.py")
build_options = (["--sdk", str(args.sdk)] if args.sdk else []) + (
    ["--build-system", args.build_system] if args.build_system else []
)
run("swift", "build", *build_options, "-c", configuration, "-j", "4")
build = pathlib.Path(
    subprocess.check_output(
        ["swift", "build", *build_options, "-c", configuration, "--show-bin-path"],
        cwd=root,
        text=True,
    ).strip()
)
stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
out = root / "artifacts" / stamp
out.mkdir(parents=True)
app = out / "AInauten Voice.app"
contents = app / "Contents"
for name in ["MacOS", "Frameworks", "Resources"]:
    (contents / name).mkdir(parents=True)
shutil.copy2(root / "Resources/Info.plist", contents / "Info.plist")
if public_key or args.local:
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    if args.local:
        for key in list(info):
            if key.startswith("SU"):
                del info[key]
        info["AInautenLocalBuild"] = True
    else:
        info["SUPublicEDKey"] = public_key
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
shutil.copy2(build / "VoiceWispr", contents / "MacOS/VoiceWispr")
for bundle in build.glob("*.bundle"):
    shutil.copytree(bundle, contents / "Resources" / bundle.name)
framework = (
    root / "Vendor/build-apple/llama.xcframework/macos-arm64_x86_64/llama.framework"
)
shutil.copytree(framework, contents / "Frameworks/llama.framework", symlinks=True)
sparkle_distribution = root / ".build/artifacts/sparkle/Sparkle"
sparkle = contents / "Frameworks/Sparkle.framework"
shutil.copytree(
    sparkle_distribution / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework",
    sparkle,
    symlinks=True,
)
shutil.copytree(root / "Resources/Licenses", contents / "Resources/Licenses")
shutil.copy2(
    sparkle_distribution / "LICENSE", contents / "Resources/Licenses/Sparkle-MIT.txt"
)
shutil.copy2(user_report, contents / "Resources/verification-report.md")
# Only our adapter/installer is bundled. Research sources and model weights
# remain in the user's private support directory after explicit Beta setup.
lip = contents / "Resources/LipReading"
lip.mkdir()
for source in (root / "lipreading_runtime").glob("*.py"):
    shutil.copy2(source, lip / source.name)
for name in ["pyproject.toml", "uv.lock"]:
    source = root / "lipreading_runtime" / name
    if source.exists():
        shutil.copy2(source, lip / name)
shutil.copytree(root / "lipreading_runtime/licenses", lip / "licenses")
shutil.copytree(
    root / "lipreading_runtime/german",
    lip / "german",
    ignore=shutil.ignore_patterns("__pycache__", ".venv"),
)
uv = args.uv or pathlib.Path("/opt/homebrew/Cellar/uv/0.12.5/bin/uv")
if not uv.exists():
    raise SystemExit(
        "Pinned uv 0.12.5 is required for packaging the optional installer"
    )
if subprocess.check_output([str(uv), "--version"], text=True).split()[:2] != [
    "uv",
    "0.12.5",
]:
    raise SystemExit("The optional installer requires uv 0.12.5")
shutil.copy2(uv, lip / "uv")
for name in ["LICENSE-MIT", "LICENSE-APACHE"]:
    license_source = uv.parents[1] / name
    if not license_source.exists():
        license_source = uv.parent / "licenses" / ("uv-" + name)
    shutil.copy2(license_source, lip / "licenses" / ("uv-" + name))
run("codesign", "--force", "--sign", identity, str(lip / "uv"))
iconset = out / "VoiceWispr.iconset"
run("swift", str(root / "scripts/make-icon.swift"), str(iconset))
run(
    "iconutil",
    "-c",
    "icns",
    str(iconset),
    "-o",
    str(contents / "Resources/VoiceWispr.icns"),
)
run(
    "install_name_tool",
    "-add_rpath",
    "@executable_path/../Frameworks",
    str(contents / "MacOS/VoiceWispr"),
)
run(
    "codesign",
    "--force",
    "--sign",
    identity,
    str(contents / "Frameworks/llama.framework"),
)
# Re-sign actual nested helpers inside out; do not follow framework symlinks.
sparkle_version = sparkle / "Versions/B"
for helper in sorted(sparkle_version.glob("XPCServices/*.xpc")):
    run(
        "codesign",
        "--force",
        "--options",
        "runtime",
        "--preserve-metadata=entitlements",
        "--sign",
        identity,
        str(helper),
    )
run(
    "codesign",
    "--force",
    "--options",
    "runtime",
    "--preserve-metadata=entitlements",
    "--sign",
    identity,
    str(sparkle_version / "Autoupdate"),
)
run(
    "codesign",
    "--force",
    "--options",
    "runtime",
    "--preserve-metadata=entitlements",
    "--sign",
    identity,
    str(sparkle_version / "Updater.app"),
)
run("codesign", "--force", "--sign", identity, str(sparkle))
# Local certificates have no Team ID: bundled llama/Sparkle require the
# library-validation exception. No JIT, DYLD injection or debug exception.
run(
    "codesign",
    "--force",
    "--options",
    "runtime",
    "--entitlements",
    str(root / "Resources/Release.entitlements"),
    "--sign",
    identity,
    str(app),
)
run("codesign", "--verify", "--deep", "--strict", str(app))
if args.local:
    verify_runtime(app)
    local = root / ".local"
    local.mkdir(exist_ok=True)
    link = local / app.name
    if link.exists() and not link.is_symlink():
        raise SystemExit(
            "The local app path is occupied; existing files were preserved"
        )
    prepared_link = local / ("prepared-app-" + stamp)
    prepared_link.symlink_to(os.path.relpath(app, local))
    prepared_link.replace(link)
else:
    dmg = create_dmg(app, out)
if args.install:
    system_apps = pathlib.Path("/Applications")
    apps = args.install_directory or (
        system_apps
        if (system_apps / app.name).exists() and os.access(system_apps, os.W_OK)
        else pathlib.Path.home() / "Applications"
    )
    apps.mkdir(exist_ok=True)
    target = apps / app.name
    previous = [path for path in [target, apps / "Voice Wispr.app"] if path.exists()]
    if previous:
        backup = pathlib.Path.home() / "AI/backups" / f"ainauten-voice-app-{stamp}"
        backup.mkdir(parents=True, exist_ok=False)
        for path in previous:
            path.rename(backup / path.name)
    shutil.copytree(app, target, symlinks=True)
    print("INSTALLED", target)
print("APP", app)
if not args.local:
    print("DMG", dmg)
