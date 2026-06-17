#!/usr/bin/env python3
"""claude-telegram-gateway dispatcher

여러 봇 토큰을 봇별로 long-poll 하는 단일 프로세스(봇별 스레드).
수신 메시지를 (bot, user_id) 조합으로 라우팅해서, tmux 세션 <user>_<bot> 에
<channel> 태그로 paste-buffer 주입한다. 전송은 각 세션의 reply-mcp 가 한다.

설정: ../config.json (예시는 config.example.json), ../.env (봇 토큰).
"""

import json
import os
import sys
import time
import threading
import subprocess
import urllib.request
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CONFIG_FILE = os.path.join(ROOT, "config.json")
ENV_FILE = os.path.join(ROOT, ".env")
STATE_DIR = os.path.join(ROOT, "state")
LOG_FILE = os.path.join(ROOT, "logs", "dispatcher.log")

_log_lock = threading.Lock()
_inject_lock = threading.Lock()  # tmux 버퍼는 전역 1개 → 주입 직렬화


def log(msg):
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    with _log_lock:
        print(line, flush=True)
        try:
            os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
            with open(LOG_FILE, "a") as f:
                f.write(line + "\n")
        except Exception:
            pass


def load_env():
    if not os.path.isfile(ENV_FILE):
        return
    with open(ENV_FILE) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())


def load_config():
    with open(CONFIG_FILE) as f:
        return json.load(f)


def api(token, method, params=None, timeout=40):
    url = f"https://api.telegram.org/bot{token}/{method}"
    data = urllib.parse.urlencode(params).encode() if params else None
    req = urllib.request.Request(url, data=data)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def extract_attachment(msg):
    for kind in ("voice", "audio", "video", "document"):
        if kind in msg:
            return msg[kind]["file_id"], kind
    if "photo" in msg:
        return msg["photo"][-1]["file_id"], "photo"
    return None, None


def build_channel_tag(msg, bot_key):
    chat_id = msg["chat"]["id"]
    message_id = msg["message_id"]
    frm = msg.get("from", {})
    user = frm.get("first_name", "") or frm.get("username", "")
    user_id = frm.get("id", "")
    ts = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(msg.get("date", time.time())))
    text = msg.get("text") or msg.get("caption") or ""
    file_id, kind = extract_attachment(msg)
    attrs = [
        'source="plugin:telegram:telegram"',
        f'bot="{bot_key}"',
        f'chat_id="{chat_id}"',
        f'message_id="{message_id}"',
        f'user="{user}"',
        f'user_id="{user_id}"',
        f'ts="{ts}"',
    ]
    if file_id:
        attrs.append(f'attachment_file_id="{file_id}"')
        attrs.append(f'attachment_kind="{kind}"')
    return "<channel " + " ".join(attrs) + f">\n{text}\n</channel>"


def inject(target, payload):
    # tmux set-buffer 는 전역 버퍼라 주입을 직렬화한다. target 은 pane id(%N).
    with _inject_lock:
        subprocess.run(["tmux", "set-buffer", "--", payload], check=True)
        subprocess.run(["tmux", "paste-buffer", "-p", "-d", "-t", target], check=True)
        time.sleep(0.4)
        subprocess.run(["tmux", "send-keys", "-t", target, "Enter"], check=True)


def find_pane(tmux_session, uname, bkey):
    """사용자 윈도우(uname) 안에서 @bot == bkey 인 pane id 를 찾는다(start.sh 가 set-option -p @bot 으로 새김)."""
    try:
        out = subprocess.run(
            ["tmux", "list-panes", "-t", f"{tmux_session}:{uname}",
             "-F", "#{@bot}\t#{pane_id}"],
            capture_output=True, text=True, check=True).stdout
    except subprocess.CalledProcessError:
        return None
    for line in out.splitlines():
        if "\t" not in line:
            continue
        bot, pid = line.split("\t", 1)
        if bot == bkey:
            return pid
    return None


def offset_path(bot_key):
    return os.path.join(STATE_DIR, f"offset_{bot_key}")


def read_offset(bot_key):
    try:
        with open(offset_path(bot_key)) as f:
            return int(f.read().strip())
    except Exception:
        return 0


def write_offset(bot_key, n):
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(offset_path(bot_key), "w") as f:
        f.write(str(n))


def poll_bot(bot_key, token, users, tmux_session):
    offset = read_offset(bot_key)
    log(f"[{bot_key}] poller start. offset={offset}")
    while True:
        try:
            resp = api(token, "getUpdates",
                       {"offset": offset, "timeout": 30, "allowed_updates": json.dumps(["message"])})
        except Exception as e:
            log(f"[{bot_key}] getUpdates error: {e}")
            time.sleep(3)
            continue
        if not resp.get("ok"):
            log(f"[{bot_key}] not ok: {resp}")
            time.sleep(3)
            continue
        for upd in resp.get("result", []):
            offset = max(offset, upd["update_id"] + 1)
            write_offset(bot_key, offset)
            msg = upd.get("message")
            if not msg:
                continue
            user_id = str(msg.get("from", {}).get("id", ""))
            user = users.get(user_id)
            preview = (msg.get("text") or msg.get("caption") or "<non-text>")[:50]
            if not user:
                log(f"[{bot_key}] UNROUTED user_id={user_id} text={preview!r}")
                continue
            target = find_pane(tmux_session, user["name"], bot_key)
            if not target:
                log(f"[{bot_key}] PANE NOT FOUND — user={user['name']} (윈도우/@bot 확인). 메시지 보류.")
                continue
            try:
                inject(target, build_channel_tag(msg, bot_key))
                log(f"[{bot_key}] -> {user['name']}/{bot_key} ({target}) msg_id={msg['message_id']} text={preview!r}")
            except subprocess.CalledProcessError as e:
                log(f"[{bot_key}] INJECT FAIL target={target}: {e}")


def main():
    load_env()
    config = load_config()
    users = {k: v for k, v in config["users"].items() if not k.startswith("_")}
    tmux_session = config.get("tmuxSession", "telegram")
    bots = {k: v for k, v in config["bots"].items() if not k.startswith("_")}

    threads = []
    for bot_key, bot in bots.items():
        token = os.environ.get(bot["tokenEnv"], "")
        if not token:
            log(f"[{bot_key}] SKIP — no token in env {bot['tokenEnv']}")
            continue
        t = threading.Thread(target=poll_bot, args=(bot_key, token, users, tmux_session), daemon=True)
        t.start()
        threads.append(t)

    if not threads:
        log("FATAL: no bots with tokens. check .env")
        sys.exit(1)

    log(f"dispatcher up. bots={list(bots)} users={[u['name'] for u in users.values()]}")
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
