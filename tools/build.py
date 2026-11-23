#!/usr/bin/env python3
"""Packs every plugins/<folder> into dist/<id>.flua and writes index.json.

The client reads index.json from the "main" branch: the packages, newest
first, with their sizes and SHA-256. A plugin is packed again only when its
sources change (index.json keeps a hash of them), so an unchanged plugin
keeps its file, its hash and its date, and is not posted again.

    python tools/build.py          # pack what changed
    python tools/build.py --all    # pack everything again
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGINS = os.path.join(ROOT, "plugins")
DIST = os.path.join(ROOT, "dist")
INDEX = os.path.join(ROOT, "index.json")
PACK = os.path.join(ROOT, "tools", "flua_pack.py")
SKIP = {"__pycache__", ".DS_Store"}


def sources_hash(folder):
    digest = hashlib.sha256()
    for base, dirs, files in os.walk(folder):
        dirs[:] = sorted(d for d in dirs if d not in SKIP)
        for name in sorted(files):
            if name in SKIP or name.endswith(".pyc"):
                continue
            path = os.path.join(base, name)
            relative = os.path.relpath(path, folder).replace(os.sep, "/")
            digest.update(relative.encode("utf-8") + b"\0")
            with open(path, "rb") as f:
                digest.update(f.read())
            digest.update(b"\0")
    return digest.hexdigest()


def file_hash(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--all", action="store_true", help="pack everything")
    args = parser.parse_args()

    old = {}
    if os.path.exists(INDEX):
        with open(INDEX, encoding="utf-8") as f:
            for entry in json.load(f).get("plugins", []):
                old[entry["id"]] = entry

    os.makedirs(DIST, exist_ok=True)
    entries = []
    seen = set()
    for name in sorted(os.listdir(PLUGINS)):
        folder = os.path.join(PLUGINS, name)
        manifest_path = os.path.join(folder, "manifest.json")
        if not os.path.isfile(manifest_path):
            continue
        with open(manifest_path, encoding="utf-8") as f:
            manifest = json.load(f)
        plugin_id = manifest["id"]
        if plugin_id in seen:
            sys.exit(f"{name}: id {plugin_id} is used twice")
        seen.add(plugin_id)

        file = f"dist/{plugin_id}.flua"
        output = os.path.join(ROOT, file)
        sources = sources_hash(folder)
        previous = old.get(plugin_id)
        if (not args.all
                and previous
                and previous.get("sources") == sources
                and os.path.isfile(output)
                and file_hash(output) == previous.get("sha256")):
            entries.append(previous)
            print(f"  {plugin_id} {manifest.get('version')}: unchanged")
            continue

        subprocess.run(
            [sys.executable, PACK, folder, "-o", output],
            check=True)
        size = os.path.getsize(output)
        entries.append({
            "id": plugin_id,
            "version": manifest.get("version", ""),
            "file": file,
            "size": size,
            "sha256": file_hash(output),
            "sources": sources,
            "date": int(time.time()),
        })
        print(f"+ {plugin_id} {manifest.get('version')}: packed, {size} bytes")

    # Packages of removed plugins go away too.
    for name in os.listdir(DIST):
        if name.endswith(".flua") and name[:-5] not in seen:
            os.remove(os.path.join(DIST, name))
            print(f"- {name[:-5]}: removed")

    entries.sort(key=lambda e: (-e.get("date", 0), e["id"]))
    with open(INDEX, "w", encoding="utf-8", newline="\n") as f:
        json.dump({"format": 1, "plugins": entries}, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"index.json: {len(entries)} plugins")


if __name__ == "__main__":
    main()
