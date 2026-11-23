#!/usr/bin/env python3
"""Keeps one post per plugin in the Telegram channel, in step with index.json.

- A new plugin gets a new post with its .flua.
- An updated plugin gets its post edited: the file and the caption are
  replaced, so the channel never keeps old versions (a bot may delete only
  messages younger than 48 hours, but may edit its posts at any time).
  A short text message tells the subscribers about the update; the catalog
  of the client reads only files, so it is not in the way.
- A plugin removed from index.json gets its post deleted if Telegram allows
  it (younger than 48 hours); otherwise the log asks to delete it by hand.

The posts are remembered in channel.json. Runs in GitHub Actions; the bot
token comes from the TELEGRAM_BOT_TOKEN secret (the bot must be an admin of
the channel that can post, edit and delete messages), the channel from
TELEGRAM_CHAT. Without a token nothing is posted.

    python tools/telegram.py          # what changed
    python tools/telegram.py --all    # every plugin again
"""

import argparse
import html
import json
import os
import sys
import urllib.error
import urllib.request
import uuid
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INDEX = os.path.join(ROOT, "index.json")
STATE = os.path.join(ROOT, "channel.json")
CAPTION_LIMIT = 1024


class TelegramError(Exception):
    pass


class Bot:
    def __init__(self, token):
        self.url = f"https://api.telegram.org/bot{token}/"

    def call(self, method, fields, files=None):
        boundary = uuid.uuid4().hex
        parts = []
        for key, value in fields.items():
            if not isinstance(value, str):
                value = json.dumps(value, ensure_ascii=False)
            parts.append(
                f"--{boundary}\r\nContent-Disposition: form-data; name=\"{key}\"\r\n\r\n"
                .encode("utf-8") + value.encode("utf-8") + b"\r\n")
        for key, (name, data) in (files or {}).items():
            parts.append(
                f"--{boundary}\r\nContent-Disposition: form-data; name=\"{key}\"; "
                f"filename=\"{name}\"\r\nContent-Type: application/octet-stream\r\n\r\n"
                .encode("utf-8") + data + b"\r\n")
        parts.append(f"--{boundary}--\r\n".encode("utf-8"))
        request = urllib.request.Request(
            self.url + method,
            data=b"".join(parts),
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                answer = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            answer = json.loads(error.read().decode("utf-8") or "{}")
        if not answer.get("ok"):
            raise TelegramError(answer.get("description", "unknown error"))
        return answer.get("result")


def manifest_of(path):
    with zipfile.ZipFile(path) as archive:
        return json.loads(archive.read("manifest.json").decode("utf-8"))


def texts(manifest):
    # The channel speaks Russian: the Russian texts, if the plugin has them.
    localized = manifest.get("localized", {}).get("ru", {})
    name = localized.get("name") or manifest.get("name", "")
    description = localized.get("description") or manifest.get("description", "")
    return name, description


def caption(manifest):
    name, description = texts(manifest)
    head = f"<b>{html.escape(name)}</b> {html.escape(manifest.get('version', ''))}"
    tail = f"\n\n#{manifest['id'].split('.')[-1].replace('-', '_')}"
    room = CAPTION_LIMIT - len(head) - len(tail) - 2
    text = description if len(description) <= room else description[:room - 1] + "…"
    return f"{head}\n\n{html.escape(text)}{tail}"


def file_name(plugin_id):
    return plugin_id.split(".")[-1] + ".flua"


def post_link(chat, message_id):
    if chat.startswith("@"):
        return f"https://t.me/{chat[1:]}/{message_id}"
    return ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--all", action="store_true", help="every plugin again")
    args = parser.parse_args()

    token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    chat = os.environ.get("TELEGRAM_CHAT", "") or "@fuckgramplugins"
    notify = os.environ.get("TELEGRAM_NOTIFY", "yes").lower() not in ("no", "0", "false")
    if not token:
        print("TELEGRAM_BOT_TOKEN is not set: nothing is posted.")
        return
    bot = Bot(token)

    with open(INDEX, encoding="utf-8") as f:
        index = {e["id"]: e for e in json.load(f).get("plugins", [])}
    state = {"chat": chat, "posts": {}}
    if os.path.exists(STATE):
        with open(STATE, encoding="utf-8") as f:
            saved = json.load(f)
        if saved.get("chat") == chat:
            state = saved
    posts = state.setdefault("posts", {})

    failed = 0

    def save():
        with open(STATE, "w", encoding="utf-8", newline="\n") as f:
            json.dump(state, f, ensure_ascii=False, indent=2, sort_keys=True)
            f.write("\n")

    # The oldest first: the newest ends up at the bottom of the channel.
    for entry in sorted(index.values(), key=lambda e: (e.get("date", 0), e["id"])):
        plugin_id = entry["id"]
        post = posts.get(plugin_id)
        if post and post.get("sha256") == entry["sha256"] and not args.all:
            continue
        path = os.path.join(ROOT, entry["file"])
        manifest = manifest_of(path)
        with open(path, "rb") as f:
            data = f.read()
        document = (file_name(plugin_id), data)
        text = caption(manifest)
        try:
            message_id = None
            if post and post.get("message_id"):
                try:
                    bot.call("editMessageMedia", {
                        "chat_id": chat,
                        "message_id": str(post["message_id"]),
                        "media": {
                            "type": "document",
                            "media": "attach://file",
                            "caption": text,
                            "parse_mode": "HTML",
                        },
                    }, {"file": document})
                    message_id = post["message_id"]
                    print(f"edited {plugin_id} {entry.get('version', '')}")
                except TelegramError as error:
                    if "not modified" in str(error).lower():
                        message_id = post["message_id"]
                    else:
                        # Deleted by hand, or too old to find: a new post.
                        print(f"could not edit {plugin_id}: {error}; posting anew")
            updated = message_id is not None
            if not updated:
                result = bot.call("sendDocument", {
                    "chat_id": chat,
                    "caption": text,
                    "parse_mode": "HTML",
                }, {"document": document})
                message_id = result["message_id"]
                print(f"posted {plugin_id} {entry.get('version', '')}")
            previous = (post or {}).get("version")
            posts[plugin_id] = {
                "message_id": message_id,
                "sha256": entry["sha256"],
                "version": entry.get("version", ""),
            }
            save()
            if updated and notify and previous != entry.get("version"):
                name, _ = texts(manifest)
                link = post_link(chat, message_id)
                title = f"<b>{html.escape(name)}</b>"
                if link:
                    title = f"<a href=\"{link}\">{title}</a>"
                bot.call("sendMessage", {
                    "chat_id": chat,
                    "text": f"\U0001F504 {title} обновлён до версии "
                            f"{html.escape(entry.get('version', ''))}",
                    "parse_mode": "HTML",
                    "link_preview_options": {"is_disabled": True},
                })
        except Exception as error:  # one plugin does not stop the rest
            failed += 1
            print(f"could not publish {plugin_id}: {error}", file=sys.stderr)

    for plugin_id in sorted(set(posts) - set(index)):
        message_id = posts[plugin_id].get("message_id")
        try:
            bot.call("deleteMessage", {"chat_id": chat, "message_id": str(message_id)})
            print(f"deleted the post of {plugin_id}")
        except TelegramError as error:
            print(f"::warning::{plugin_id} is gone from the catalog, but its post "
                  f"{post_link(chat, message_id) or message_id} can not be deleted "
                  f"by the bot ({error}): delete it by hand.")
        del posts[plugin_id]
        save()

    save()
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
