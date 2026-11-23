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
import re
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
        if not files:
            # Without files: JSON. An empty multipart form is sometimes
            # answered with "400" and no text.
            request = urllib.request.Request(
                self.url + method,
                data=json.dumps(fields, ensure_ascii=False).encode("utf-8"),
                headers={"Content-Type": "application/json"})
            return self.send(request)
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
        return self.send(request)

    def send(self, request):
        status = 200
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                body = response.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as error:
            status = error.code
            body = error.read().decode("utf-8", "replace")
        try:
            answer = json.loads(body or "{}")
        except ValueError:
            answer = {}
        if not answer.get("ok"):
            description = answer.get("description") or body[:200] or "no answer"
            raise TelegramError(f"HTTP {status}: {description}")
        return answer.get("result")


def annotate(level, message):
    # GitHub shows these on the run page, also to those who can not read
    # the log. Telegram errors never contain the token.
    message = str(message).replace("\n", " ")
    print(f"::{level}::{message}", flush=True)


def check_bot(bot, chat):
    """The bot exists, sees the channel and may post, edit and delete."""
    try:
        me = bot.call("getMe", {})
    except Exception as error:
        annotate("error", f"TELEGRAM_BOT_TOKEN does not work: {error}")
        return False
    name = "@" + me.get("username", "?")
    try:
        info = bot.call("getChat", {"chat_id": chat})
    except Exception as error:
        annotate("error", f"{name} can not see {chat}: {error}. Add the bot "
                          f"to the channel as an admin (or check TELEGRAM_CHAT).")
        return False
    try:
        member = bot.call("getChatMember", {
            "chat_id": chat,
            "user_id": str(me["id"]),
        })
    except Exception as error:
        if "inaccessible" in str(error):
            # Only admins of a channel see who is in it.
            annotate("error", f"{name} is not an admin of {chat}: add it to "
                              f"the channel admins with \"Post messages\", "
                              f"\"Edit messages of others\" and \"Delete "
                              f"messages of others\".")
        else:
            annotate("error", f"{name} in {chat}: {error}")
        return False
    status = member.get("status")
    if status not in ("administrator", "creator"):
        annotate("error", f"{name} is '{status}' in {chat} "
                          f"({info.get('type')}), it must be an admin.")
        return False
    missing = [right for right in (
        "can_post_messages",
        "can_edit_messages",
        "can_delete_messages",
    ) if not member.get(right)]
    if "can_post_messages" in missing:
        annotate("error", f"{name} is an admin of {chat} without "
                          f"\"Post messages\".")
        return False
    if missing:
        annotate("warning", f"{name} in {chat} has no "
                            f"{', '.join(missing)}: updates of old posts "
                            f"or removals may fail.")
    print(f"{name} is an admin of {chat}: ok")
    return True


def manifest_of(path):
    with zipfile.ZipFile(path) as archive:
        return json.loads(archive.read("manifest.json").decode("utf-8"))


def name_of(manifest):
    # The channel is English only: the default (English) name.
    return manifest.get("name", "") or manifest.get("id", "")


def size_text(size):
    if size < 1024:
        return f"{size} B"
    return f"{size / 1024:.1f} KB"


def caption(manifest, entry):
    # Technical values only, in English.
    api = manifest.get("api", {})
    api_min = api.get("min", 1)
    api_max = api.get("max", api_min)
    rows = [
        ("id", manifest.get("id", "")),
        ("version", manifest.get("version", "")),
        ("api", f"{api_min}" if api_min == api_max else f"{api_min}-{api_max}"),
        ("permissions", ", ".join(manifest.get("permissions", [])) or "none"),
        ("categories", ", ".join(manifest.get("categories", [])) or "none"),
        ("languages", ", ".join(sorted(
            {"en"} | set(manifest.get("localized", {}).keys())))),
        ("size", size_text(entry["size"])),
        ("sha256", entry["sha256"]),
    ]
    lines = [f"<b>{html.escape(name_of(manifest))}</b>", ""]
    for key, value in rows:
        lines.append(f"{key}: <code>{html.escape(str(value))}</code>")
    text = "\n".join(lines)
    return text[:CAPTION_LIMIT]


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

    # Pasted tokens often bring spaces, line breaks or a "bot" prefix.
    raw = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    token = re.sub(r"\s+", "", raw)
    if token.lower().startswith("bot") and ":" in token:
        token = token[3:]
    if token and token != raw:
        annotate("warning", "TELEGRAM_BOT_TOKEN had spaces, line breaks or "
                            "a \"bot\" prefix: they are dropped. Better fix "
                            "the secret.")
    if token and not re.fullmatch(r"\d{5,}:[A-Za-z0-9_-]{30,}", token):
        annotate("error", "TELEGRAM_BOT_TOKEN does not look like a bot token "
                          "(digits, a colon, then 35 letters, as @BotFather "
                          f"gives it); it has {len(token)} characters.")
        sys.exit(1)
    chat = os.environ.get("TELEGRAM_CHAT", "") or "@fuckgramplugins"
    notify = os.environ.get("TELEGRAM_NOTIFY", "yes").lower() not in ("no", "0", "false")
    if not token:
        print("TELEGRAM_BOT_TOKEN is not set: nothing is posted.")
        return
    bot = Bot(token)
    if not check_bot(bot, chat):
        sys.exit(1)

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
        text = caption(manifest, entry)
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
                        annotate("warning", f"could not edit the post of "
                                            f"{plugin_id}: {error}; posting anew")
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
                link = post_link(chat, message_id)
                title = f"<code>{html.escape(plugin_id)}</code>"
                if link:
                    title = f"<a href=\"{link}\">{title}</a>"
                versions = html.escape(
                    f"{previous or '?'} -> {entry.get('version', '')}")
                bot.call("sendMessage", {
                    "chat_id": chat,
                    "text": f"updated: {title} {versions}",
                    "parse_mode": "HTML",
                    "link_preview_options": {"is_disabled": True},
                })
        except Exception as error:  # one plugin does not stop the rest
            failed += 1
            annotate("error", f"could not publish {plugin_id}: {error}")

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
