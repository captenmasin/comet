#!/usr/bin/env python3
"""Exercise release ordering and rejection paths without Apple credentials or network access."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
STUB = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
tool, args = Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ["RELEASE_TRACE"], "a") as trace:
    trace.write(json.dumps([tool, *args]) + "\n")
if tool == "lipo":
    print("arm64")
elif tool == "hdiutil":
    image = Path(args[args.index("-srcfolder") + 1])
    assert (image / "Applications").is_symlink()
    assert os.readlink(image / "Applications") == "/Applications"
    assert (image / "Comet.app/Contents/ticket").exists()
    artwork = Path("Artwork/Installer")
    assert (image / ".DS_Store").read_bytes() == (artwork / "FinderLayout").read_bytes()
    assert (image / ".background/background.png").read_bytes() == (artwork / "background.png").read_bytes()
    assert args[args.index("-fs") + 1] == "HFS+"
    Path(args[-1]).write_bytes(b"DMG fixture")
elif tool == "xcrun":
    if args[:2] == ["notarytool", "submit"]:
        kind = "DMG" if args[2].endswith(".dmg") else "APP"
        print(json.dumps({"id": "fixture-id", "status": os.environ.get(kind + "_STATUS", "Accepted")}))
        sys.exit(int(os.environ.get("SUBMIT_EXIT", "0")))
    elif args[:2] == ["stapler", "staple"] and args[2].endswith(".app"):
        (Path(args[2]) / "Contents/ticket").touch()
    if os.environ.get("FAIL_STAPLE") and args[:2] == ["stapler", "validate"]:
        sys.exit(1)
elif tool == "spctl" and os.environ.get("FAIL_GATEKEEPER"):
    sys.exit(1)
elif tool == "generate_appcast":
    assert sys.stdin.read().strip() == "fixture-sparkle-key"
    assert args[args.index("--download-url-prefix") + 1] == "https://github.com/captenmasin/comet/releases/download/v1.2.3/"
    assert args[args.index("--link") + 1] == "https://github.com/captenmasin/comet/releases/tag/v1.2.3"
    if os.environ.get("FAIL_APPCAST"):
        sys.exit(1)
    (Path(args[-1]) / "appcast.xml").write_text("<rss>Signed feed fixture</rss>\n")
elif tool == "sign_update":
    assert sys.stdin.read().strip() == "fixture-sparkle-key"
    if os.environ.get("FAIL_FEED_SIGNATURE"):
        sys.exit(1)
'''


def check_release(**overrides):
    with tempfile.TemporaryDirectory(prefix="comet-release-test-") as temporary:
        root = Path(temporary)
        (root / "scripts").mkdir()
        shutil.copy2(ROOT / "scripts/release.sh", root / "scripts/release.sh")
        shutil.copytree(ROOT / "Artwork/Installer", root / "Artwork/Installer")
        shutil.copy2(ROOT / "Comet.entitlements", root / "Comet.entitlements")
        app = root / ".build/release/Comet.app/Contents"
        (app / "MacOS").mkdir(parents=True)
        (app / "MacOS/Comet").write_bytes(b"Executable fixture")
        framework = app / "Frameworks/Sparkle.framework/Versions/B"
        for component in ("XPCServices/Downloader.xpc", "XPCServices/Installer.xpc", "Updater.app"):
            (framework / component).mkdir(parents=True)
        (framework / "Autoupdate").touch()
        with (app / "Info.plist").open("wb") as file:
            plistlib.dump({"CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "42"}, file)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for tool in ("xcrun", "codesign", "spctl", "hdiutil", "lipo"):
            stub = bin_dir / tool
            stub.write_text(STUB)
            stub.chmod(0o755)
        tools = root / ".build/artifacts/sparkle/Sparkle/bin"
        tools.mkdir(parents=True)
        for tool in ("generate_appcast", "sign_update"):
            (tools / tool).write_text(STUB)
            (tools / tool).chmod(0o755)
        trace = root / "trace.jsonl"
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", VERSION="1.2.3", BUILD_NUMBER="42",
                   SIGNING_IDENTITY="Developer ID Application: Fixture (TEAM)", NOTARY_PROFILE="fixture",
                   NOTARY_KEYCHAIN=str(root / "fixture.keychain-db"), SPARKLE_PRIVATE_KEY="fixture-sparkle-key",
                   RELEASE_TRACE=str(trace), **overrides)
        env["SIGNING_KEYCHAIN"] = str(root / "fixture-signing.keychain-db")
        # Stale deliverables must not survive a failed notarization or assessment.
        dist = root / ".build/dist"
        dist.mkdir()
        (dist / "Comet.dmg").touch()
        (dist / "appcast.xml").touch()
        (dist / "SHA256SUMS").touch()
        result = subprocess.run(["zsh", str(root / "scripts/release.sh")], env=env, capture_output=True, text=True)
        calls = [json.loads(line) for line in trace.read_text().splitlines()]
        rejected = bool(overrides)
        assert (result.returncode != 0) == rejected, result.stdout + result.stderr
        assert (dist / "Comet.dmg").exists() != rejected
        assert (dist / "appcast.xml").exists() != rejected
        assert (dist / "SHA256SUMS").exists() != rejected
        assert not list((root / ".build").glob("release-package.*")), result.stdout + result.stderr
        submissions = [call for call in calls if call[:3] == ["xcrun", "notarytool", "submit"]]
        assert all("--keychain" in call and "--keychain-profile" in call for call in submissions)
        signatures = [call for call in calls if call[0] == "codesign" and "--sign" in call]
        assert all(call[call.index("--keychain") + 1] == env["SIGNING_KEYCHAIN"] for call in signatures)
        if not rejected:
            assert [Path(call[3]).suffix for call in submissions] == [".zip", ".dmg"]
            manifest = "".join(f"{hashlib.sha256((dist / name).read_bytes()).hexdigest()}  {name}\n"
                               for name in ("Comet.dmg", "appcast.xml"))
            assert (dist / "SHA256SUMS").read_text() == manifest
            assessments = [call for call in calls if call[0] == "spctl"]
            assert len(assessments) == 2
        elif overrides.get("APP_STATUS") or overrides.get("SUBMIT_EXIT"):
            assert len(submissions) == 1, "DMG was submitted after the app was rejected"
            assert any(call[:3] == ["xcrun", "notarytool", "log"] for call in calls)


def check_update_copy():
    with tempfile.TemporaryDirectory(prefix="comet-update-copy-") as temporary:
        framework = Path(temporary) / "Sparkle.framework"
        strings = framework / "Versions/B/Resources/Base.lproj/Sparkle.strings"
        strings.parent.mkdir(parents=True)
        key = "%@ %@ is now available—you have %@. Would you like to download it now?"
        value = "%1$@ %2$@ is now available—you have %3$@. Would you like to download it now?"
        strings.write_bytes(plistlib.dumps({key: value, "Install Update": "Install Update"}, fmt=plistlib.FMT_BINARY))
        result = subprocess.run(["python3", str(ROOT / "scripts/customize-sparkle.py"), str(framework)],
                                capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        updated = plistlib.loads(strings.read_bytes())
        assert set(updated) == {key, "Install Update"}
        assert updated[key] == "%1$@ %2$@ is now available. You have %3$@. Would you like to download it now?"
        assert updated["Install Update"] == "Install Update"
        result = subprocess.run(["python3", str(ROOT / "scripts/customize-sparkle.py"), str(framework)],
                                capture_output=True, text=True)
        assert result.returncode != 0 and "expected update prompt" in result.stderr


if __name__ == "__main__":
    check_update_copy()
    check_release()
    check_release(APP_STATUS="Invalid")
    check_release(DMG_STATUS="Invalid")
    check_release(APP_STATUS="In Progress")
    check_release(SUBMIT_EXIT="65", APP_STATUS="Invalid")
    check_release(FAIL_STAPLE="1")
    check_release(FAIL_GATEKEEPER="1")
    check_release(FAIL_APPCAST="1")
    check_release(FAIL_FEED_SIGNATURE="1")
    for overrides in ({"VERSION": "../invalid"}, {"VERSION": "1.2.3-beta"}, {"BUILD_NUMBER": "0"},
                      {"CONFIGURATION": "unknown"}):
        result = subprocess.run(["zsh", str(ROOT / "scripts/build-app.sh")],
                                env=dict(os.environ, **overrides), capture_output=True, text=True)
        assert result.returncode != 0 and "Expected CONFIGURATION" in result.stderr, result.stderr
    print("Release checks passed (Apple tools stubbed; no credentials used).")
