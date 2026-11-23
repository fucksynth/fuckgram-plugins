#!/usr/bin/env python3
"""Pack a plugin folder into a .flua file.

    python tools/flua_pack.py examples/plugins/hello            # -> example.hello.flua
    python tools/flua_pack.py examples/plugins/hello -o out.flua

Checks the same things the client checks before it loads a package:
manifest.json, id, entry file, known permissions, no native files and
size limits, and the texts in other languages: "localized" in the
manifest and locales/<language>.json for plugin.t(). A .flua is a plain
zip with manifest.json at its root.
"""
import argparse
import json
import os
import re
import sys
import zipfile

KNOWN_PERMISSIONS = {
    "player",
    "messages.read", "messages.send", "ui", "storage", "links",
    "actions", "display", "chats.read", "compose", "mtproto",
    "messages.manage",
}
KNOWN_CATEGORIES = {"appearance", "chats", "media", "privacy", "tools", "integrations", "fun", "libraries"}
NET_HOST = r"^(\*\.)?[a-z0-9]([a-z0-9\-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9\-]*[a-z0-9])?)+$"
NATIVE = (".dll", ".so", ".dylib", ".exe", ".pyd")
MAX_FILE = 4 * 1024 * 1024
MAX_TOTAL = 16 * 1024 * 1024
MAX_FILES = 512
API_VERSION = 1
# Language codes as the client gives them: "ru", "en", "pt-br".
LANGUAGE = r"^[a-z]{2,3}(-[a-z0-9]{2,8})*$"
LOCALIZED_FIELDS = {"name", "description"}
PLURAL_FORMS = {"one", "few", "many", "other"}


def fail(message):
    print("error: " + message, file=sys.stderr)
    sys.exit(1)


def warn(message):
    print("warning: " + message, file=sys.stderr)


def check_localized(manifest):
    """"localized": { "ru": { "name": "...", "description": "..." } }"""
    localized = manifest.get("localized")
    if localized is None:
        return
    if not isinstance(localized, dict):
        fail("localized must be an object of language -> { name, description }")
    for language, texts in localized.items():
        if not re.match(LANGUAGE, language):
            fail("localized: bad language code %r, use lowercase like ru, en, pt-br"
                 % language)
        if not isinstance(texts, dict):
            fail("localized.%s must be an object with name and description" % language)
        for field, value in texts.items():
            if not isinstance(value, str):
                fail("localized.%s.%s must be a string" % (language, field))
            if field not in LOCALIZED_FIELDS:
                warn("localized.%s.%s is not used, only name and description are"
                     % (language, field))


def check_locales(root, files):
    """locales/<language>.json: flat objects of texts for plugin.t()."""
    locales = {}
    for relative, full in files:
        if not relative.startswith("locales/"):
            continue
        name = relative[len("locales/"):]
        if not name.endswith(".json") or "/" in name:
            warn("plugin.t() reads only locales/<language>.json, not " + relative)
            continue
        language = name[:-len(".json")]
        if not re.match(LANGUAGE, language):
            fail("%s: bad language code, use lowercase like ru, en, pt-br" % relative)
        with open(full, encoding="utf-8") as stream:
            try:
                strings = json.load(stream)
            except ValueError as error:
                fail("%s: %s" % (relative, error))
        if not isinstance(strings, dict):
            fail(relative + ": must be an object of key -> text")
        for key, value in strings.items():
            if isinstance(value, str):
                continue
            if not isinstance(value, dict):
                fail("%s: %r must be a string or a plural object" % (relative, key))
            if not value:
                fail("%s: %r: the plural object is empty" % (relative, key))
            for form, text in value.items():
                if form not in PLURAL_FORMS:
                    fail("%s: %r: unknown plural form %r, use one, few, many, other"
                         % (relative, key, form))
                if not isinstance(text, str):
                    fail("%s: %r.%s must be a string" % (relative, key, form))
        locales[language] = strings
    if not locales:
        return
    if "en" not in locales:
        fail("locales/en.json is missing: it is the fallback for every language")
    keys = set(locales["en"])
    for language in sorted(locales):
        if language == "en":
            continue
        missing = sorted(keys - set(locales[language]))
        extra = sorted(set(locales[language]) - keys)
        if missing:
            warn("locales/%s.json has no %s (English is shown)"
                 % (language, ", ".join(missing)))
        if extra:
            warn("locales/%s.json has keys that en.json has not: %s"
                 % (language, ", ".join(extra)))


def collect(root):
    files = []
    for folder, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for name in names:
            if name.startswith("."):
                continue
            full = os.path.join(folder, name)
            relative = os.path.relpath(full, root).replace(os.sep, "/")
            if relative.lower().endswith(NATIVE):
                fail("native code is not allowed: " + relative)
            if os.path.getsize(full) > MAX_FILE:
                fail("file is too large: " + relative)
            files.append((relative, full))
    if len(files) > MAX_FILES:
        fail("too many files")
    if sum(os.path.getsize(full) for _, full in files) > MAX_TOTAL:
        fail("package is too large")
    return sorted(files)


def check_manifest(root, files):
    path = os.path.join(root, "manifest.json")
    if not os.path.exists(path):
        fail("manifest.json is missing")
    with open(path, encoding="utf-8") as stream:
        try:
            manifest = json.load(stream)
        except ValueError as error:
            fail("manifest.json: " + str(error))
    plugin_id = manifest.get("id", "")
    if not re.match(r"^[a-z0-9][a-z0-9_.\-]{1,63}$", plugin_id):
        fail("bad id, use 2-64 of a-z 0-9 _ . -")
    if not manifest.get("name"):
        fail("name is missing")
    names = {relative for relative, _ in files}
    entry = manifest.get("entry", "init.lua")
    if entry not in names:
        fail("entry file is missing: " + entry)
    icon = manifest.get("icon", "")
    if icon and icon not in names:
        fail("icon file is missing: " + icon)
    api = manifest.get("api", {})
    low, high = api.get("min", 1), api.get("max", api.get("min", 1))
    if low > API_VERSION or high < API_VERSION:
        fail("needs plugin API %d-%d, the client has %d" % (low, high, API_VERSION))
    categories = manifest.get("categories", [])
    if isinstance(manifest.get("category"), str):
        categories = categories + [manifest["category"]]
    for category in categories:
        if str(category).strip().lower() not in KNOWN_CATEGORIES:
            warn("unknown category, the catalog skips it: " + str(category))
    for permission in manifest.get("permissions", []):
        if permission.startswith("net:"):
            if not re.match(NET_HOST, permission[4:]):
                fail("bad network permission: " + permission)
        elif permission not in KNOWN_PERMISSIONS:
            fail("unknown permission: " + permission)
    check_localized(manifest)
    check_locales(root, files)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("folder")
    parser.add_argument("-o", "--output")
    args = parser.parse_args()

    root = os.path.abspath(args.folder)
    files = collect(root)
    manifest = check_manifest(root, files)
    output = args.output or (manifest["id"] + ".flua")
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for relative, full in files:
            archive.write(full, relative)
    print("%s: %s %s, %d files" % (
        output, manifest["id"], manifest.get("version", ""), len(files)))


if __name__ == "__main__":
    main()
