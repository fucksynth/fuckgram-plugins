# fuckgram plugins

Official plugins of [fuckgram](https://github.com/fucksynth/fuckgram). The
client reads this repository as a verified source of its plugin catalog
(Settings → Plugins → Plugin catalog), and the channel
[@fuckgramplugins](https://t.me/fuckgramplugins) keeps one post per plugin.

- `plugins/<name>/` — sources: `manifest.json`, `init.lua`, `locales/`,
  `resources/`. The plugin API is in
  [docs/plugins.md](https://github.com/fucksynth/fuckgram/blob/release/docs/plugins.md).
- `dist/<id>.flua` — packages built from the sources.
- `index.json` — what the client reads: packages, newest first, with their
  sizes and SHA-256. A file that does not match is not shown.
- `channel.json` — the posts of the plugins in the channel.

## Releasing a plugin

Change the sources, bump `version` in `manifest.json`, push to `main`.
The workflow "Publish plugins" does the rest:

1. packs the plugins whose sources changed (`tools/build.py`) and updates
   `index.json` — the catalog shows the new version within minutes;
2. posts a new plugin to the channel, or replaces the file and the caption
   in the post of an updated one and sends a short "updated" message —
   the channel never keeps old versions (`tools/telegram.py`);
3. commits `dist/`, `index.json` and `channel.json` back (pull before your
   next push).

Telegram needs the repository secret `TELEGRAM_BOT_TOKEN`: a bot that is an
admin of the channel allowed to post, edit and delete messages. Optional
variables: `TELEGRAM_CHAT` (default `@fuckgramplugins`), `TELEGRAM_NOTIFY`
(`no` — no "updated" messages). A bot may delete only messages younger
than 48 hours: the post of a plugin removed later is deleted by hand (the
workflow log says which).

---

Официальные плагины [fuckgram](https://github.com/fucksynth/fuckgram).
Клиент читает этот репозиторий как проверенный источник каталога плагинов,
а в канале [@fuckgramplugins](https://t.me/fuckgramplugins) у каждого
плагина один пост.

Выпуск: поменять исходники и `version`, запушить в `main`. Action «Publish
plugins» соберёт пакеты, обновит `index.json` (каталог увидит новую версию
через пару минут), выложит новый плагин в канал или заменит файл и подпись
в посте обновлённого и напишет короткое «обновлён» — старых версий в канале
не остаётся. Нужен секрет `TELEGRAM_BOT_TOKEN`: бот — админ канала с правом
публиковать, редактировать и удалять сообщения.
