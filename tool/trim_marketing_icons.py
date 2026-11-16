"""Drop App Store marketing icons from every appiconset before an IPA build.

The bundle carries six selectable app icons; each appiconset also ships a
1024x1024 `ios-marketing` PNG that iOS never loads on device -- it exists only
so App Store Connect can render the listing. Xcode compiles all six of them
into Assets.car, which costs several MiB in the shipped IPA.

This script rewrites the checked-in asset catalog *in the build workspace only*:
it removes the marketing entry from Contents.json and deletes the referenced
PNG. Nothing is committed, so the store-submission capability is unchanged --
a normal `flutter build ipa` for upload still sees the 1024 icons.

Idempotent: a second run finds no marketing entries and exits quietly.
"""

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "ios/Runner/Assets.xcassets"
MARKETING_IDIOMS = {"ios-marketing"}


def trim(appiconset: Path, dry_run: bool) -> tuple[int, list[str]]:
    manifest = appiconset / "Contents.json"
    if not manifest.exists():
        return 0, []
    data = json.loads(manifest.read_text(encoding="utf-8"))
    images = data.get("images")
    if not isinstance(images, list):
        return 0, []

    kept, dropped, freed = [], [], 0
    for entry in images:
        if entry.get("idiom") in MARKETING_IDIOMS:
            dropped.append(entry)
        else:
            kept.append(entry)
    if not dropped:
        return 0, []

    # Only touch files this entry points at, and only if no surviving entry
    # still references the same filename.
    survivors = {e.get("filename") for e in kept if e.get("filename")}
    for entry in dropped:
        name = entry.get("filename")
        if not name or name in survivors:
            continue
        target = appiconset / name
        if target.is_file():
            freed += target.stat().st_size
            if not dry_run:
                target.unlink()

    if not dry_run:
        data["images"] = kept
        manifest.write_text(
            json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
    return freed, [e.get("filename", "?") for e in dropped]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="report without writing")
    args = parser.parse_args()

    if not CATALOG.is_dir():
        print(f"asset catalog not found: {CATALOG}", file=sys.stderr)
        return 1

    total = 0
    touched = 0
    for appiconset in sorted(CATALOG.glob("*.appiconset")):
        freed, names = trim(appiconset, args.dry_run)
        if freed or names:
            touched += 1
            total += freed
            print(f"  {appiconset.name}: -{freed / 1048576:.2f} MiB ({len(names)} marketing icon)")

    verb = "would free" if args.dry_run else "freed"
    print(f"{touched} appiconset(s), {verb} {total / 1048576:.2f} MiB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
