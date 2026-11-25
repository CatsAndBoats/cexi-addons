"""
ClamAV pass over the staged files.

Runs once, over everything, after staging and before any upload. The extension
allow-list in vetting.py is the primary defence; this is the second opinion that
catches a malicious payload wearing an allowed extension.
"""

import shutil
import subprocess

from util import error, info, warn


def available():
    return shutil.which("clamscan") is not None


def scan(staging_dir, required=True):
    """
    Scan the staging tree. Returns True when clean.

    Exit codes: 0 clean, 1 infected, 2 error (usually a missing virus database).
    A scanner error is treated as a failure when required, because "we could not
    check" and "it is fine" are not the same thing.
    """
    if not available():
        if required:
            error("clamscan is not installed and the ClamAV scan is required")
            return False
        warn("clamscan not installed; skipping virus scan")
        return True

    info(f"    scanning {staging_dir}")
    result = subprocess.run(
        ["clamscan", "--recursive", "--infected", "--no-summary", str(staging_dir)],
        capture_output=True,
        text=True,
    )

    if result.returncode == 0:
        info("    ClamAV: clean")
        return True

    if result.returncode == 1:
        error("ClamAV found infected files. Nothing will be uploaded.")
        for line in result.stdout.strip().splitlines():
            error(f"  {line}")
        return False

    message = (result.stderr or result.stdout).strip()
    if required:
        error(f"ClamAV could not complete the scan (exit {result.returncode}): {message}")
        return False

    warn(f"ClamAV error (exit {result.returncode}), continuing because the scan is optional: {message}")
    return True
