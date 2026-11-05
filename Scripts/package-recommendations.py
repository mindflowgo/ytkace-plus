#!/usr/bin/env python3
"""Copy an expanded IPA, add the recommendations patch, and package it for
sideloader re-signing.

The input .app and its existing YTKACE.dylib are never modified. The output
uses ad-hoc signing and is not an already provisioned install for a stock
iPhone. Do not install this build alongside the RecommendationProbe; both
dylibs hook the same selectors.
"""

import argparse
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools"))
from macho_inject import atomic_write, list_dylibs, rewrite
from inspect_recommendations import ObjCImage


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for data in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(data)
    return digest.hexdigest()


def version_numbers(dist_dir, youtube_version):
    """Existing patch IPA versions: dev-ATS builds are `..._Recommendations_vN.ipa`,
    the no-ATS variant is `..._Recommendations_vN_clean.ipa`."""
    pattern = re.compile(
        rf"YTKACE_{re.escape(youtube_version)}_Recommendations_v(\d+)(?:_clean)?\.ipa$")
    dev, clean = [], []
    if dist_dir.is_dir():
        for path in dist_dir.iterdir():
            match = pattern.match(path.name)
            if match:
                (clean if path.name.endswith("_clean.ipa") else dev).append(int(match.group(1)))
    return dev, clean


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--dylib", type=Path, default=ROOT / "dist/recommendations/YTKACERecommendations.dylib")
    parser.add_argument("--output", type=Path, default=None,
                        help="explicit output path; default auto-increments the version number")
    parser.add_argument("--clean", action="store_true",
                        help="package the no-ATS-exception variant (…_vN_clean.ipa) of the latest build")
    parser.add_argument("--version", type=int, default=None,
                        help="explicit version number instead of auto-increment (clean defaults to the latest dev build)")
    parser.add_argument("--allow-insecure-http-dev", action="store_true",
                        help="dev only: add NSAppTransportSecurity/NSAllowsArbitraryLoads to the COPY's "
                             "Info.plist so http:// LAN server URLs work. Never ship a build with this flag.")
    args = parser.parse_args()
    app, dylib = args.app.resolve(), args.dylib.resolve()
    original_input = app
    if not dylib.is_file():
        parser.error("provide a built recommendations dylib (Scripts/build-recommendations.sh)")
    # Accept either an expanded .app or a distributable .ipa (a zip holding a
    # Payload/ directory with the app — e.g. the YTKACE GitHub release files).
    ipa_source: tempfile.TemporaryDirectory | None = None
    if app.suffix == ".ipa":
        if not app.is_file():
            parser.error(f"input IPA not found: {app}")
        ipa_source = tempfile.TemporaryDirectory(prefix="ytkace-plus-app-ipa-")
        extract_dir = Path(ipa_source.name) / "Payload"
        subprocess.run(["unzip", "-q", str(app), "-d", str(ipa_source.name)], check=True)
        apps = sorted(p for p in extract_dir.glob("*.app") if p.is_dir())
        if len(apps) != 1:
            parser.error(f"expected exactly one .app inside Payload/, found {len(apps)}")
        app = apps[0]
    elif app.suffix != ".app" or not app.is_dir():
        parser.error("provide an expanded .app or a distributable .ipa, plus a built dylib")
    if args.allow_insecure_http_dev and args.clean:
        parser.error("--clean builds carry no ATS exception; drop one of the flags")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    version = re.sub(r"[^A-Za-z0-9._-]", "_", str(info.get("CFBundleShortVersionString", "unknown")))
    dist_dir = ROOT / "dist"
    dev_versions, clean_versions = version_numbers(dist_dir, version)
    if args.version is not None:
        patch_version = args.version
    elif args.clean:
        # A clean build is a variant of the latest dev-ATS build (or 1 if none yet).
        patch_version = max(dev_versions) if dev_versions else (max(clean_versions) if clean_versions else 1)
    else:
        patch_version = max(dev_versions + clean_versions, default=0) + 1
    if args.output is not None:
        output = args.output.resolve()
    else:
        suffix = "_clean" if args.clean else ""
        output = (dist_dir / f"YTKACE_{version}_Recommendations_v{patch_version}{suffix}.ipa").resolve()
    if output == dylib or output.suffix != ".ipa" or app in output.parents:
        parser.error("output must be a separate .ipa outside the input app")
    executable = info["CFBundleExecutable"]
    if Path(executable).name != executable:
        parser.error("invalid CFBundleExecutable")
    main_binary = app / executable
    existing_tweak = app / "Frameworks/YTKACE.dylib"
    original_hash = sha256(main_binary)
    tweak_hash = sha256(existing_tweak) if existing_tweak.exists() else None
    source_bytes = main_binary.read_bytes()
    image = ObjCImage(source_bytes)
    if image.encryption != 0:
        parser.error("a verified decrypted executable (cryptid=0) is required")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ytkace-recommendations-") as temporary:
        work = Path(temporary)
        destination = work / "Payload/YouTube.app"
        shutil.copytree(app, destination, symlinks=True)
        frameworks = destination / "Frameworks"
        frameworks.mkdir(exist_ok=True)
        target_dylib = frameworks / "YTKACERecommendations.dylib"
        shutil.copy2(dylib, target_dylib)
        modified = rewrite(source_bytes, add_load="@rpath/YTKACERecommendations.dylib")
        atomic_write(destination / executable, modified)
        (destination / executable).chmod(main_binary.stat().st_mode & 0o777)
        if args.allow_insecure_http_dev:
            info_plist = destination / "Info.plist"
            dev_info = plistlib.loads(info_plist.read_bytes())
            existing = dev_info.get("NSAppTransportSecurity")
            if isinstance(existing, dict) and existing.get("NSAllowsArbitraryLoads") is True:
                pass
            else:
                security = dict(existing) if isinstance(existing, dict) else {}
                security["NSAllowsArbitraryLoads"] = True
                dev_info["NSAppTransportSecurity"] = security
                info_plist.write_bytes(plistlib.dumps(dev_info))
        subprocess.run(["codesign", "--force", "--sign", "-", str(target_dylib)], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", "--preserve-metadata=entitlements",
                        str(destination)], check=True)
        subprocess.run(["codesign", "--verify", str(destination)], check=True)
        loads = list_dylibs((destination / executable).read_bytes())[0]
        assert loads.count("@rpath/YTKACERecommendations.dylib") == 1
        assert loads.count("@rpath/YTKACERecommendationProbe.dylib") == 0, \
            "source app already contains the probe; remove it before packaging the production patch"
        assert not tweak_hash or sha256(frameworks / "YTKACE.dylib") == tweak_hash
        archive = work / "recommendations.ipa"
        subprocess.run(["zip", "-qry", str(archive), "Payload"], cwd=work, check=True)
        shutil.move(str(archive), str(output))
    assert sha256(main_binary) == original_hash, "input executable changed"
    assert not tweak_hash or sha256(existing_tweak) == tweak_hash, "input tweak changed"
    if ipa_source is not None:
        ipa_source.cleanup()
    report = {
        "sourceApp": str(original_input), "youtubeVersion": info.get("CFBundleShortVersionString"),
        "minimumOSVersion": info.get("MinimumOSVersion"), "cryptid": image.encryption,
        "patchVersion": patch_version, "variant": "clean" if args.clean else "dev-ats",
        "sourceExecutableSHA256": original_hash, "preservedYTKACESHA256": tweak_hash,
        "patchSHA256": sha256(dylib), "outputSHA256": sha256(output),
        "output": str(output), "signing": "ad-hoc; must be re-signed by iLoader or another sideloader",
        "patchLoadCount": loads.count("@rpath/YTKACERecommendations.dylib"),
        "atsDevException": bool(args.allow_insecure_http_dev),
    }
    output.with_suffix(".manifest.json").write_text(json.dumps(report, indent=2) + "\n")
    print(output)


if __name__ == "__main__":
    main()
