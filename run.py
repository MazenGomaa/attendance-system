#!/usr/bin/env python3
"""
run.py — cross-platform bootstrap launcher
===========================================
Copy this folder to ANY device that has Python 3.9+ and run:

    python run.py            (Windows)
    python3 run.py           (Linux / macOS / Termux)

On first run it:
  1. checks the Python version (3.9+ required),
  2. creates a private virtual environment in ./.venv  (no global installs),
  3. installs the dependencies into it,
  4. downloads the matching `cloudflared` binary for this OS/CPU if missing,
then starts the server. Subsequent runs skip straight to launching (a marker
file records that deps are installed). Nothing is installed system-wide.

Works on Linux, macOS, Windows, and Termux (Android).
"""

import os
import platform
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

# ---------------------------------------------------------------------------
# Python version guard — asyncio.to_thread requires 3.9+
# ---------------------------------------------------------------------------
if sys.version_info < (3, 9):
    print(f"[error] Python 3.9 or later is required (you have {platform.python_version()}).")
    print("        Download the latest Python from https://www.python.org/downloads/")
    sys.exit(1)

HERE = os.path.dirname(os.path.abspath(__file__))
VENV = os.path.join(HERE, ".venv")
MARK = os.path.join(VENV, ".deps_installed")
CF_RELEASE = "https://github.com/cloudflare/cloudflared/releases/latest/download/"

# (import_name, install_name) pairs for the quick missing-package check.
REQUIRED_PACKAGES = [
    ("fastapi", "fastapi"),
    ("uvicorn", "uvicorn"),
    ("qrcode", "qrcode"),
    ("multipart", "python-multipart"),
]


def venv_python() -> str:
    """Path to the python interpreter inside our private venv."""
    if os.name == "nt":
        return os.path.join(VENV, "Scripts", "python.exe")
    return os.path.join(VENV, "bin", "python")


def _ask_yes(question: str) -> bool:
    """Prompt y/N; default yes."""
    try:
        return input(f"{question} [Y/n]: ").strip().lower() != "n"
    except (EOFError, KeyboardInterrupt):
        return True


def _missing_packages() -> list:
    """Return install-names of packages missing from the venv."""
    missing = []
    for import_name, pkg_name in REQUIRED_PACKAGES:
        r = subprocess.run(
            [venv_python(), "-c", f"import {import_name}"],
            capture_output=True,
        )
        if r.returncode != 0:
            missing.append(pkg_name)
    return missing


def _install_deps():
    req = os.path.join(HERE, "requirements.txt")
    print("[setup] installing dependencies (may take a minute on first run) …")
    try:
        subprocess.check_call(
            [venv_python(), "-m", "pip", "install", "--upgrade", "pip", "--quiet"]
        )
    except Exception:
        pass  # pip upgrade is best-effort
    subprocess.check_call([venv_python(), "-m", "pip", "install", "-r", req])
    open(MARK, "w").close()
    print("[setup] dependencies installed.")


def ensure_venv():
    if not os.path.isfile(venv_python()):
        print("[setup] creating virtual environment in .venv …")
        import venv
        venv.EnvBuilder(with_pip=True).create(VENV)

    if not os.path.isfile(MARK):
        _install_deps()
        return

    # On subsequent runs do a quick sanity check for any missing packages.
    missing = _missing_packages()
    if missing:
        print(f"[setup] missing packages: {', '.join(missing)}")
        if _ask_yes("[setup] Install missing dependencies now?"):
            _install_deps()
        else:
            print("[setup] Skipping install — the server may fail to start.")


def cloudflared_target():
    """
    Return (download_url, output_filename, archive_kind) for this platform.

    Verified against the actual release assets on cloudflare/cloudflared:
      Windows : cloudflared-windows-{amd64|386}.exe  (no arm64 binary — use amd64)
      macOS   : cloudflared-darwin-{amd64|arm64}.tgz
      Linux   : cloudflared-linux-{amd64|arm64|armhf|arm|386}
    """
    sysname = platform.system().lower()
    arch = platform.machine().lower()

    if sysname == "windows":
        # No Windows ARM64 binary exists; Windows ARM can run amd64 via emulation.
        a = "amd64" if arch in ("x86_64", "amd64", "aarch64", "arm64") else "386"
        return CF_RELEASE + f"cloudflared-windows-{a}.exe", "cloudflared.exe", None

    if sysname == "darwin":
        a = "arm64" if arch in ("aarch64", "arm64") else "amd64"
        return CF_RELEASE + f"cloudflared-darwin-{a}.tgz", "cloudflared", "tgz"

    # Linux and Android/Termux
    if arch in ("x86_64", "amd64"):
        a = "amd64"
    elif arch in ("aarch64", "arm64"):
        a = "arm64"
    elif arch.startswith("armv") or arch == "arm":
        # armhf (hard-float) covers ARMv7+ — Raspberry Pi 2/3/4, modern Android ARM32.
        # arm (soft-float) is the fallback for ARMv6 and older (e.g. Pi Zero W).
        # sysconfig reports "gnueabihf" in HOST_GNU_TYPE when Python itself was built
        # for hard-float, which is the most reliable signal available at runtime.
        try:
            import sysconfig
            host = sysconfig.get_config_var("HOST_GNU_TYPE") or ""
            a = "armhf" if "gnueabihf" in host else "arm"
        except Exception:
            # Fallback: ARMv7 and above always use hard-float in practice.
            a = "armhf" if arch.startswith("armv7") else "arm"
    elif arch in ("i386", "i686", "x86"):
        a = "386"
    else:
        a = arch
    return CF_RELEASE + f"cloudflared-linux-{a}", "cloudflared", None


def have_cloudflared() -> bool:
    from shutil import which
    if which("cloudflared"):
        return True
    return any(
        os.path.isfile(os.path.join(HERE, n))
        for n in ("cloudflared", "cloudflared.exe")
    )


def ensure_cloudflared():
    if have_cloudflared():
        return
    print("[setup] cloudflared not found (needed for public QR-code tunnel URLs).")
    if not _ask_yes("[setup] Download cloudflared now?"):
        print("[setup] Skipping — the server will run LAN-only.")
        return
    url, outname, kind = cloudflared_target()
    out = os.path.join(HERE, outname)
    print(f"[setup] downloading cloudflared …\n        {url}")
    try:
        if kind == "tgz":
            tmp = tempfile.mktemp(suffix=".tgz")
            urllib.request.urlretrieve(url, tmp)
            with tarfile.open(tmp) as t:
                for m in t.getmembers():
                    if m.name.endswith("cloudflared"):
                        m.name = os.path.basename(m.name)
                        t.extract(m, HERE)
                        break
            os.remove(tmp)
        else:
            urllib.request.urlretrieve(url, out)
        if os.name != "nt" and os.path.isfile(out):
            st = os.stat(out).st_mode
            os.chmod(out, st | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        print("[setup] cloudflared ready.")
    except Exception as e:
        print(f"[setup] download failed: {e}")
        print(
            "        The server still runs LAN-only. Install cloudflared manually from\n"
            "        https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
        )


def main():
    ensure_venv()
    ensure_cloudflared()
    print("[run] starting server …\n")
    try:
        # Launch the app with the venv's python. Ctrl+C propagates to this child,
        # triggering the graceful CSV export in main.py's lifespan hook.
        return subprocess.call([venv_python(), os.path.join(HERE, "main.py")])
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
