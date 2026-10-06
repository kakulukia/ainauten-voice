#!/usr/bin/env python3
"""Check signing selection in an isolated package tree without accessing Keychain."""

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

scripts = pathlib.Path(__file__).resolve().parent
local, release, override = "1" * 40, "2" * 40, "3" * 40
cases = [
    ("local priority", ["--local"], local, release, local, "BUILD_REACHED"),
    ("release isolation", [], local, None, local, "stable signing identity missing"),
    ("release selection", [], local, release, release, "BUILD_REACHED"),
    ("local release fallback", ["--local"], None, release, release, "BUILD_REACHED"),
    (
        "explicit override",
        ["--local", "--sign-identity", override],
        local,
        release,
        override,
        "BUILD_REACHED",
    ),
    (
        "invalid local identity",
        ["--local"],
        "invalid",
        release,
        release,
        "40-character",
    ),
    (
        "no silent ad-hoc fallback",
        ["--local", "--adhoc"],
        local,
        release,
        release,
        "refusing ad-hoc fallback",
    ),
    (
        "missing local identity",
        ["--local"],
        None,
        None,
        "",
        "stable signing identity missing",
    ),
    ("explicit ad-hoc", ["--local", "--adhoc"], None, None, "", "BUILD_REACHED"),
]

with tempfile.TemporaryDirectory(prefix="ainauten-package-signing-check-") as temporary:
    root = pathlib.Path(temporary)
    for name in ["scripts", ".local", "docs", "bin"]:
        (root / name).mkdir()
    for name in ["package.py", "package_dmg.py", "app_bundle.py"]:
        shutil.copyfile(scripts / name, root / "scripts" / name)
    (root / "docs/user-verification-report.md").write_text(
        "# AInauten Voice: Prüfbericht\n"
    )
    # Stop before compiling or signing; only packaging preflight runs.
    (root / "scripts/bootstrap.py").write_text(
        "print('BUILD_REACHED')\nraise SystemExit(73)\n"
    )
    security = root / "bin/security"
    security.write_text(
        f"#!{sys.executable}\nimport os\nprint(os.environ['AINAUTEN_CHECK_IDENTITIES'])\n"
    )
    security.chmod(0o700)
    for name, flags, local_value, release_value, available, expected in cases:
        for filename, value in [
            ("local-signing-identity", local_value),
            ("signing-identity", release_value),
        ]:
            path = root / ".local" / filename
            if value is None:
                path.unlink(missing_ok=True)
            else:
                path.write_text(value + "\n")
        env = dict(
            os.environ,
            PATH=str(root / "bin") + os.pathsep + os.environ["PATH"],
            AINAUTEN_CHECK_IDENTITIES=available,
        )
        result = subprocess.run(
            [sys.executable, str(root / "scripts/package.py"), *flags],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        output = result.stdout + result.stderr
        if (
            expected not in output
            or result.returncode == 0
            or (expected != "BUILD_REACHED" and "BUILD_REACHED" in output)
        ):
            raise SystemExit(f"FAIL {name}: {output}")
        print("PASS", name)
    (root / ".local/local-signing-identity").write_text(local + "\n")
    (root / ".local/local-app-path").write_text(str(root / "outside.app") + "\n")
    env["AINAUTEN_CHECK_IDENTITIES"] = local
    result = subprocess.run(
        [sys.executable, str(root / "scripts/package.py"), "--local"],
        env=env,
        capture_output=True,
        text=True,
        timeout=10,
    )
    output = result.stdout + result.stderr
    if (
        result.returncode == 0
        or "Unexpected local app destination" not in output
        or "BUILD_REACHED" in output
    ):
        raise SystemExit("FAIL unexpected local destination: " + output)
    print("PASS unexpected local destination rejected before building")
