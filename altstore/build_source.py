#!/usr/bin/env python3
"""Build the AltStore source JSON for one release.

Reads the previous source (the last release asset, or the copy committed in this
repository) and inserts/replaces the version entry for the build being released,
so history keeps accumulating across releases.

Called by .github/workflows/ios-release.yml; runnable by hand:

    python3 altstore/build_source.py --base altstore/source.json --output /tmp/s.json \
        --repo Pyramid-RJ/dsh-mobile-ios --tag ios-v0.1.0 --version 0.1.0 \
        --bundle-id io.example.dshmobile.ios --ipa-name DSHMobile-0.1.0-unsigned.ipa \
        --size 112153 --min-os 17.0
"""

import argparse
import json
import sys
from datetime import datetime, timezone


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True, help="previous source.json")
    parser.add_argument("--output", required=True, help="source.json to write")
    parser.add_argument("--repo", required=True, help="owner/name")
    parser.add_argument("--tag", required=True, help="release tag, e.g. ios-v0.1.0")
    parser.add_argument("--version", required=True, help="marketing version, e.g. 0.1.0")
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--ipa-name", required=True, help="asset file name of the ipa")
    parser.add_argument("--size", required=True, type=int, help="ipa size in bytes")
    parser.add_argument("--min-os", default="17.0")
    parser.add_argument("--notes", default="")
    parser.add_argument("--date", default="")
    args = parser.parse_args()

    with open(args.base, encoding="utf-8") as handle:
        source = json.load(handle)

    app = next(
        (item for item in source.get("apps", []) if item.get("bundleIdentifier") == args.bundle_id),
        None,
    )
    if app is None:
        print("no app with bundleIdentifier " + args.bundle_id + " in " + args.base, file=sys.stderr)
        return 1

    date = args.date or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    entry = {
        "version": args.version,
        "date": date,
        "downloadURL": "https://github.com/%s/releases/download/%s/%s"
        % (args.repo, args.tag, args.ipa_name),
        "size": args.size,
        "minOSVersion": args.min_os,
        "localizedDescription": args.notes or ("Unsigned build " + args.version),
    }

    versions = [item for item in app.get("versions", []) if item.get("version") != args.version]
    versions.insert(0, entry)
    app["versions"] = versions
    app["version"] = args.version
    app["versionDate"] = date
    app["versionDescription"] = entry["localizedDescription"]

    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(source, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    print("wrote %s with versions %s" % (args.output, [item["version"] for item in versions]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
