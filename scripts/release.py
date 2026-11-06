#!/usr/bin/env python3
"""Sign and publish new versions of the Hushlist installers.

Installed copies of Hushlist check for a newer installer every hour and only
install it if it is signed with your private key. This script is the only way
to make a valid release.

    python3 scripts/release.py keygen
        One time. Creates your private signing key at ~/.hushlist/signing-key.pem,
        protected by a passphrase you choose, and writes the matching public key
        into both installers.
        BACK UP THAT FILE (for example to a password manager). If you lose it,
        installed copies can't receive updates until people reinstall.
        Never commit it or share it.

    python3 scripts/release.py protect-key
        Adds a passphrase to a key created without one.

    python3 scripts/release.py publish "What changed"
        Pulls the latest code and shows you every installer change since the last
        release, with who made it. Only after you type "yes" does it bump the
        version, sign both installers, add a CHANGELOG entry, commit and push.
        Devices pick it up within about an hour of the site deploying.
        Add --no-push to stop before committing.

    python3 scripts/release.py verify
        Checks both installers are correctly signed, pass a syntax check and pass
        their own self-test. The site build runs this and refuses to deploy
        installers that fail. (The Windows checks need PowerShell, which the build has.)

Uses only the system openssl, so it runs on a stock Mac and on GitHub Actions.
"""
from __future__ import annotations

import base64
import datetime as dt
import getpass
import os
import shutil
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
MAC = ROOT / "install" / "hushlist-mac.command"
WIN = ROOT / "install" / "hushlist-windows.ps1"
CHANGELOG = ROOT / "CHANGELOG.md"
KEY = pathlib.Path(os.environ.get("HUSHLIST_SIGNING_KEY", "~/.hushlist/signing-key.pem")).expanduser()

KEY_BLOCK = re.compile(r"(# BEGIN SIGNING KEY[^\n]*\n)(.*?)(# END SIGNING KEY)", re.S)
MAC_VERSION = re.compile(r"^HUSHLIST_VERSION=(\d+)$", re.M)
WIN_VERSION = re.compile(r"^\$HushlistVersion = (\d+)$", re.M)


def fail(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


PASS_ENV = "HUSHLIST_KEY_PASSPHRASE"


def key_is_encrypted() -> bool:
    return KEY.exists() and "ENCRYPTED" in KEY.read_text(errors="replace")


def unlock_key() -> None:
    """Ask for the key's passphrase once and hand it to openssl through the environment."""
    if key_is_encrypted() and not os.environ.get(PASS_ENV):
        os.environ[PASS_ENV] = getpass.getpass(f"Passphrase for {KEY}: ")


def passin() -> list[str]:
    return ["-passin", f"env:{PASS_ENV}"] if key_is_encrypted() else []


def openssl(*args: str, data: bytes | None = None) -> bytes:
    r = subprocess.run(["openssl", *args], input=data, capture_output=True)
    if r.returncode != 0:
        fail(f"openssl {' '.join(args)} failed: {r.stderr.decode(errors='replace').strip()}")
    return r.stdout


def git(*args: str) -> str:
    r = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        fail(f"git {' '.join(args)} failed: {r.stderr.strip()}")
    return r.stdout


# ---------- keys ----------

def public_pem_from_key() -> str:
    if not KEY.exists():
        fail(f"no signing key at {KEY}. Run: python3 scripts/release.py keygen")
    return openssl("rsa", "-in", str(KEY), *passin(), "-pubout").decode().strip()


def modulus_from_pem(pem: str) -> bytes:
    with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as f:
        f.write(pem + "\n")
        path = f.name
    try:
        out = openssl("rsa", "-pubin", "-in", path, "-noout", "-modulus").decode().strip()
    finally:
        os.unlink(path)
    return bytes.fromhex(out.split("=", 1)[1])


def embedded_pem() -> str:
    m = re.search(r"^PUBKEY='([^']*)'$", MAC.read_text(), re.M)
    return m.group(1).strip() if m else ""


def embedded_win_key() -> tuple[str, str]:
    t = WIN.read_text()
    mod = re.search(r"^\$KeyModulus\s*=\s*'([^']*)'", t, re.M)
    exp = re.search(r"^\$KeyExponent\s*=\s*'([^']*)'", t, re.M)
    return (mod.group(1) if mod else "", exp.group(1) if exp else "")


def write_public_key(pem: str) -> None:
    mod = base64.b64encode(modulus_from_pem(pem)).decode()
    exp = base64.b64encode((65537).to_bytes(3, "big")).decode()   # openssl's default exponent
    for path, body in ((MAC, f"PUBKEY='{pem}'\n"),
                       (WIN, f"$KeyModulus  = '{mod}'\n$KeyExponent = '{exp}'\n")):
        t = path.read_text()
        if not KEY_BLOCK.search(t):
            fail(f"{path.name} has no SIGNING KEY block")
        path.write_text(KEY_BLOCK.sub(lambda m: m.group(1) + body + m.group(3), t, count=1))


def keygen() -> None:
    if KEY.exists():
        fail(f"{KEY} already exists. Delete it yourself first if you really mean to replace it:\n"
             "       installed copies only trust the old key, so they'd stop updating until people reinstall.")
    KEY.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    phrase = new_passphrase()
    old = os.umask(0o077)
    try:
        os.environ[PASS_ENV] = phrase
        openssl("genrsa", "-aes256", "-passout", f"env:{PASS_ENV}", "-out", str(KEY), "3072")
    finally:
        os.umask(old)
    os.chmod(KEY, 0o600)
    write_public_key(public_pem_from_key())
    print(f"Created your signing key: {KEY}")
    print("Back up the key file AND its passphrase (a password manager is ideal). Never commit or share either.")
    print("The public key is now in both installers. Next: python3 scripts/release.py publish \"What changed\"")


def new_passphrase() -> str:
    if os.environ.get(PASS_ENV):          # for scripted use and tests
        return os.environ[PASS_ENV]
    while True:
        a = getpass.getpass("Choose a passphrase for your signing key (12+ characters): ")
        if len(a) < 12:
            print("Too short. Use at least 12 characters, for example four random words.")
            continue
        if a != getpass.getpass("Type it again: "):
            print("Those didn't match. Try again.")
            continue
        return a


def protect_key() -> None:
    if not KEY.exists():
        fail(f"no signing key at {KEY}")
    if key_is_encrypted():
        print("Your signing key already has a passphrase.")
        return
    os.environ[PASS_ENV] = new_passphrase()
    tmp = KEY.with_suffix(".tmp")
    old = os.umask(0o077)
    try:
        openssl("rsa", "-aes256", "-in", str(KEY), "-passout", f"env:{PASS_ENV}", "-out", str(tmp))
    finally:
        os.umask(old)
    os.chmod(tmp, 0o600)
    os.replace(tmp, KEY)
    print(f"Done: {KEY} now needs your passphrase to sign releases. Back up the passphrase with the key.")


# ---------- signing ----------

def sign(path: pathlib.Path) -> None:
    sig = openssl("dgst", "-sha256", "-sign", str(KEY), *passin(), str(path))
    (path.parent / (path.name + ".sig")).write_text(base64.b64encode(sig).decode())


def check_sig(path: pathlib.Path, pem: str) -> bool:
    sig_path = path.parent / (path.name + ".sig")
    if not sig_path.exists():
        return False
    with tempfile.TemporaryDirectory() as d:
        key = pathlib.Path(d, "key.pem"); key.write_text(pem + "\n")
        sig = pathlib.Path(d, "sig"); sig.write_bytes(base64.b64decode(sig_path.read_text().strip()))
        r = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(key), "-signature", str(sig), str(path)],
                           capture_output=True)
    return r.returncode == 0


def versions() -> tuple[int, int]:
    m = MAC_VERSION.search(MAC.read_text())
    w = WIN_VERSION.search(WIN.read_text())
    if not m or not w:
        fail("couldn't find the version line in one of the installers")
    return int(m.group(1)), int(w.group(1))


def verify() -> None:
    problems = []
    pem = embedded_pem()
    if not pem:
        fail("no public key in the installers yet. Run: python3 scripts/release.py keygen")
    mod, exp = embedded_win_key()
    if base64.b64decode(mod or "") != modulus_from_pem(pem) or exp != "AQAB":
        problems.append("the Windows and Mac installers contain different public keys")
    mv, wv = versions()
    if mv != wv:
        problems.append(f"version mismatch: Mac is {mv}, Windows is {wv}")
    for p in (MAC, WIN):
        if not check_sig(p, pem):
            problems.append(f"{p.relative_to(ROOT)} is not signed, or was changed after signing")
    if not problems:
        problems += self_tests(mv)
    if problems:
        print("Installer check FAILED:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        print("Fix: on the Mac with the signing key, run  python3 scripts/release.py publish \"What changed\"",
              file=sys.stderr)
        sys.exit(1)
    print(f"Installers OK: version {mv}, signed.")


def self_tests(version: int) -> list[str]:
    """Run each installer's syntax check and its own self-test, as devices do before updating."""
    problems = []
    r = subprocess.run(["bash", "-n", str(MAC)], capture_output=True, text=True)
    if r.returncode != 0:
        problems.append(f"Mac installer syntax error: {r.stderr.strip()}")
    else:
        r = subprocess.run(["bash", str(MAC), "--self-test"], capture_output=True, text=True)
        if r.returncode != 0 or r.stdout.strip() != str(version):
            problems.append("Mac installer failed its self-test")
    pwsh = shutil.which("pwsh")
    if not pwsh:
        print("Note: PowerShell isn't installed here, so the Windows self-test was skipped (the site build runs it).")
        return problems
    check = ("$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile("
             f"'{WIN}', [ref]$null, [ref]$e); if ($e) {{ $e | ForEach-Object {{ $_.Message }}; exit 1 }}")
    r = subprocess.run([pwsh, "-NoProfile", "-Command", check], capture_output=True, text=True)
    if r.returncode != 0:
        problems.append(f"Windows installer syntax error: {r.stdout.strip()}")
    else:
        r = subprocess.run([pwsh, "-NoProfile", "-File", str(WIN), "-SelfTest"], capture_output=True, text=True)
        if r.returncode != 0 or r.stdout.strip() != str(version):
            problems.append("Windows installer failed its self-test")
    return problems


def review(pem: str) -> None:
    """Show every installer change since the last release and who made it; require a typed yes."""
    paths = ["install/hushlist-mac.command", "install/hushlist-windows.ps1", "install/hushlist-windows.cmd"]
    last = git("log", "-1", "--format=%H", "--", "install/hushlist-mac.command.sig").strip()
    diff = git("diff", last, "--", *paths) if last else git("diff", "--", *paths)
    if last:
        authors = git("log", "--format=  %h %an <%ae>: %s", f"{last}..HEAD", "--", *paths).rstrip()
    else:
        authors = ""
    # Ignore the version lines this script changes itself
    meaningful = [l for l in diff.splitlines()
                  if l[:1] in "+-" and not l.startswith(("+++", "---"))
                  and not MAC_VERSION.match(l[1:]) and not WIN_VERSION.match(l[1:])]
    if not meaningful:
        print("No installer changes since the last release.")
    else:
        print("=" * 72)
        print("Installer changes since the last release (this is what you're about to sign):")
        print("=" * 72)
        print(diff)
        if authors:
            print("Commits that made these changes:")
            print(authors)
        print("=" * 72)
    answer = input("Sign and publish these changes to every installed device? Type yes to continue: ")
    if answer.strip().lower() != "yes":
        fail("cancelled, nothing was signed")


def publish(notes: str, push: bool) -> None:
    if not notes.strip():
        fail('say what changed, e.g.: python3 scripts/release.py publish "Fix hosts file backup"')
    unlock_key()
    pem = public_pem_from_key()
    if embedded_pem() != pem:
        fail("the public key in the installers doesn't match your signing key at " + str(KEY))
    if push:
        git("pull", "--rebase", "--autostash", "origin", "main")
    review(pem)

    new = max(versions()) + 1
    MAC.write_text(MAC_VERSION.sub(f"HUSHLIST_VERSION={new}", MAC.read_text(), count=1))
    WIN.write_text(WIN_VERSION.sub(f"$HushlistVersion = {new}", WIN.read_text(), count=1))
    for p in (MAC, WIN):
        sign(p)
    verify()

    today = dt.date.today().isoformat()
    entry = f"## Version {new} ({today})\n\n{notes.strip()}\n\n"
    head = "# Hushlist app changelog\n\nInstalled copies update themselves within about an hour of a release.\n\n"
    body = CHANGELOG.read_text()[len(head):] if CHANGELOG.exists() and CHANGELOG.read_text().startswith(head) else ""
    CHANGELOG.write_text(head + entry + body)

    files = ["install/hushlist-mac.command", "install/hushlist-mac.command.sig",
             "install/hushlist-windows.ps1", "install/hushlist-windows.ps1.sig",
             "install/hushlist-windows.cmd", "CHANGELOG.md"]
    if not push:
        print(f"Version {new} signed. Not pushed: review, then commit {', '.join(files)}")
        return
    git("add", *files)
    git("commit", "-m", f"Release app version {new}\n\n{notes.strip()}")
    git("push", "origin", "main")
    print(f"Released version {new}. Devices will install it within about an hour of the site deploying.")


def main() -> None:
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return
    cmd = args[0]
    if cmd == "keygen":
        keygen()
    elif cmd == "verify":
        verify()
    elif cmd == "protect-key":
        protect_key()
    elif cmd == "publish":
        rest = [a for a in args[1:] if a != "--no-push"]
        publish(" ".join(rest), push="--no-push" not in args)
    else:
        fail(f"unknown command {cmd!r}. Use keygen, protect-key, publish or verify.")


if __name__ == "__main__":
    main()
