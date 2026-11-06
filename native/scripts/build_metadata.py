"""Record the source revision of a development bundle without changing release versions."""

import datetime
import subprocess


def development_build_info(root):
    info = {
        "AInautenBuildDate": datetime.datetime.now().astimezone().date().isoformat()
    }
    try:
        revision = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=root, text=True, stderr=subprocess.DEVNULL
        ).strip()
        changes = subprocess.check_output(
            ["git", "status", "--porcelain", "--untracked-files=normal", "--", "."],
            cwd=root,
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return info
    info.update(AInautenBuildCommit=revision, AInautenBuildDirty=bool(changes.strip()))
    return info
