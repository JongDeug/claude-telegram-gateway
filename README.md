# claude-telegram-gateway

Run multiple **Claude Code** personas over Telegram — one isolated session per `(bot × user)`, with memory shared per user.

A single dispatcher polls every bot, routes each message to the right tmux session by `(bot, user_id)`, and each session replies through a tiny send-only MCP. Personas are per-bot; memory is per-user and shared across bots.

> 한 줄 요약: 텔레그램 봇 여러 개(각자 인격)를 사용자별 격리 세션으로 돌리되, 같은 사용자의 기억은 봇을 가로질러 공유한다.

## Why this shape

Telegram's Bot API has one hard constraint:

- **Receiving** (`getUpdates` long-poll) allows only **one consumer per bot token** — two pollers on the same bot collide (HTTP 409).
- **Sending** (`sendMessage`) can happen from anywhere, concurrently.

So this project **splits receive from send**:

```
[bots]  captain(token) / hulk(token) / ...        ← each bot = a persona
   │ one poller per bot token (dispatcher)
[dispatcher]  route by (bot, user_id)
   │ tmux paste-buffer injection of a <channel> tag
[sessions]  alice_captain / alice_hulk / bob_captain / bob_hulk   ← session = bot × user
   │ each session replies via reply-mcp (sendMessage only, no polling → no 409)
[reply-mcp]  sends with that session's bot token
```

- **Session = bot × user.** Personas never bleed into each other; two users never share a conversation.
- **Memory = per user.** `alice_captain` and `alice_hulk` read/write the *same* user workspace, so Alice's history follows her across bots.
- **Persona = per bot.** `IDENTITY.md` / `SOUL.md` live under `personas/<name>/`; everything else (USER, MEMORY, memory/,运영 docs) is shared per user.

## Architecture notes

- **`--strict-mcp-config` is required.** Each session is launched with `--strict-mcp-config --mcp-config <session>/.mcp.json` so it loads *only* the send-only reply-mcp. Without it, a session auto-loads any globally-installed Telegram plugin and starts its own poller — colliding with the dispatcher. Hooks still load from the session's `.claude/settings.json`, unaffected by strict mode.
- **reply-mcp server name is `plugin_telegram_telegram`,** which makes its tools resolve as `mcp__plugin_telegram_telegram__reply` — so the prompt/format/stop hooks and reply rules are reusable as-is.
- **Tokens live only in `.env`.** Sessions receive a `BOT_KEY` (e.g. `hulk`); reply-mcp resolves `BOT_HULK_TOKEN` from `.env`. No token is ever written into a session config or committed.

## Layout

```
claude-telegram-gateway/
  config.example.json     # bots, users, shared-file policy → copy to config.json
  .env.example            # BOT_<KEY>_TOKEN → copy to .env
  src/
    dispatcher.py         # multi-bot poller + (bot,user_id) routing + paste-buffer injection
    reply-mcp/server.js   # send-only MCP (reply/edit/react/download), token via BOT_KEY→.env
    hooks/
      prompt-hook.sh      # inject persona(per-bot) + user data(shared); excludes obsidian etc.
      reply-format-hook.sh
      stop-enforce-reply.sh
  personas/<name>/        # IDENTITY.md, SOUL.md per bot persona
  workspaces/<user>/      # USER.md, MEMORY.md, memory/, ... (gitignored; per-user data)
  scripts/start.sh|stop.sh
```

## Setup

```bash
cp config.example.json config.json     # define bots + users
cp .env.example .env                    # fill in BOT_<KEY>_TOKEN
# create personas/<name>/IDENTITY.md (+ SOUL.md) per bot
# create workspaces/<user>/USER.md (+ memory/) per user
bash scripts/start.sh                    # spawns (user × bot) sessions + dispatcher in tmux
tail -f logs/dispatcher.log
```

Requirements: `tmux` (3.2+ for bracketed paste), `python3`, `bun` (for reply-mcp), and the `claude` CLI.

## Routing data shapes

- `config.json` → `bots.<key> = { tokenEnv, persona }`, `users.<user_id> = { name, workspace }`
- A message from `user_id` on bot `key` → session `<users[user_id].name>_<key>`.
- `sharedWorkspaceFiles` / `sharedWorkspaceDirs` decide what the prompt-hook injects per user; `excludeDirs` (e.g. `obsidian`) is never touched.

## Credits / prior art

Shape converged with and borrowed ideas from:
[claude-gateway](https://github.com/0xMaxMa/claude-gateway) (persona/memory assembly, receiver/send split),
[praktor](https://github.com/mtzanidakis/praktor) (named-agent routing),
[ccgram](https://github.com/jsayubi/ccgram) (tmux keystroke injection).

## License

MIT
