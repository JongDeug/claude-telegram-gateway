#!/usr/bin/env bun
// claude-telegram-gateway reply-mcp
// 전송 전용 경량 MCP 서버 — 봇 폴링(getUpdates)은 디스패처가 전담하고,
// 이 서버는 sendMessage / editMessageText / setMessageReaction / getFile 만 한다.
// 폴링을 하지 않으므로 같은 봇 토큰으로 여러 세션이 동시에 떠도 충돌하지 않는다.
//
// MCP 서버 이름을 .mcp.json 에서 "plugin_telegram_telegram" 로 등록하면
// 툴 이름이 mcp__plugin_telegram_telegram__reply 가 되어 텔레그램 훅
// (prompt / format / stop-enforce) 과 운영 규칙을 그대로 재활용한다.
//
// 토큰: 세션은 .mcp.json env 로 BOT_KEY(예: "hulk") 만 받고, 실제 토큰은
// repo 루트 .env 의 BOT_<KEY>_TOKEN 에서 읽는다 → 토큰이 config/세션설정에 안 박힌다.
//
// 프로토콜: MCP stdio = newline-delimited JSON-RPC 2.0 (한 줄 = 한 메시지).

import { readFileSync, appendFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { md2tg } from "./md2tg.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..", ".."); // src/reply-mcp → repo root

function readEnvVar(name) {
  try {
    const env = readFileSync(join(ROOT, ".env"), "utf8");
    for (const line of env.split("\n")) {
      const m = line.match(new RegExp(`^\\s*${name}\\s*=\\s*(.+)\\s*$`));
      if (m) return m[1].trim();
    }
  } catch {}
  return null;
}

function loadToken() {
  if (process.env.TELEGRAM_BOT_TOKEN) return process.env.TELEGRAM_BOT_TOKEN;
  const botKey = process.env.BOT_KEY;
  if (botKey) {
    const fromProc = process.env[`BOT_${botKey.toUpperCase()}_TOKEN`];
    if (fromProc) return fromProc;
    return readEnvVar(`BOT_${botKey.toUpperCase()}_TOKEN`);
  }
  return readEnvVar("TELEGRAM_BOT_TOKEN");
}

const TOKEN = loadToken();
const API = (method) => `https://api.telegram.org/bot${TOKEN}/${method}`;
const FILE_API = (path) => `https://api.telegram.org/file/bot${TOKEN}/${path}`;
const DL_DIR = join(ROOT, "inbox");

const DEBUG = !!process.env.GATEWAY_MCP_DEBUG;
const DBG_FILE = join(ROOT, "logs", "mcp-debug.log");
function log(...args) {
  // stdout 은 JSON-RPC 전용이므로 로그는 stderr 로만.
  process.stderr.write("[reply-mcp] " + args.map(String).join(" ") + "\n");
}
function dbg(dir, obj) {
  if (!DEBUG) return;
  try {
    appendFileSync(DBG_FILE, `${dir} ${typeof obj === "string" ? obj : JSON.stringify(obj)}\n`);
  } catch {}
}

async function tg(method, payload) {
  const res = await fetch(API(method), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  const json = await res.json();
  if (!json.ok) throw new Error(`${method} failed: ${json.description || res.status}`);
  return json.result;
}

// multipart 전송 (사진/문서 첨부)
async function tgUpload(method, fields, fileField, filePath) {
  const form = new FormData();
  for (const [k, v] of Object.entries(fields)) {
    if (v !== undefined && v !== null) form.append(k, String(v));
  }
  const buf = readFileSync(filePath);
  const name = filePath.split("/").pop();
  form.append(fileField, new Blob([buf]), name);
  const res = await fetch(API(method), { method: "POST", body: form });
  const json = await res.json();
  if (!json.ok) throw new Error(`${method} failed: ${json.description || res.status}`);
  return json.result;
}

const isImage = (p) => /\.(png|jpe?g|gif|webp)$/i.test(p);

// ---- 툴 구현 ----

// 포맷 적용 — 기본은 마크다운 → 텔레그램 HTML 자동 변환(OpenClaw 식).
//   (미지정)/"markdown"/"text" → md2tg + parse_mode HTML : claude 가 낸 마크다운을 예쁘게
//   "raw"        → 변환·parse_mode 없이 원문 그대로
//   "html"       → 변환 없이 HTML (이미 텔레그램 HTML 인 경우)
//   "markdownv2" → 변환 없이 MarkdownV2 (하위호환)
function applyFormat(base, text, format) {
  if (format === "raw") return text;
  if (format === "markdownv2") { base.parse_mode = "MarkdownV2"; return text; }
  if (format === "html") { base.parse_mode = "HTML"; return text; }
  base.parse_mode = "HTML";
  return md2tg(text);
}

async function doReply(args) {
  const { chat_id, text, reply_to, format, files } = args;
  if (!chat_id) throw new Error("chat_id required");
  const base = { chat_id };
  // allow_sending_without_reply: 원본 메시지를 못 찾아도(삭제/포럼 등) 일반 전송으로 보낸다.
  if (reply_to) base.reply_parameters = { message_id: Number(reply_to), allow_sending_without_reply: true };
  const outText = text ? applyFormat(base, text, format) : text;

  const sentIds = [];
  // 첨부가 있으면 첨부부터 (첫 첨부에 caption 으로 text)
  if (Array.isArray(files) && files.length) {
    for (let i = 0; i < files.length; i++) {
      const fp = files[i];
      const fields = { chat_id };
      if (base.reply_parameters) fields.reply_parameters = JSON.stringify(base.reply_parameters);
      if (i === 0 && outText) {
        fields.caption = outText;
        if (base.parse_mode) fields.parse_mode = base.parse_mode;
      }
      const method = isImage(fp) ? "sendPhoto" : "sendDocument";
      const field = isImage(fp) ? "photo" : "document";
      const r = await tgUpload(method, fields, field, fp);
      sentIds.push(r.message_id);
    }
    return `sent (id: ${sentIds.join(", ")})`;
  }

  if (!outText) throw new Error("text or files required");
  // 변환된 HTML 이 텔레그램에서 거부되면(드묾) parse_mode 빼고 원문 plain 으로 폴백 — 전송 자체는 보장.
  try {
    const r = await tg("sendMessage", { ...base, text: outText });
    return `sent (id: ${r.message_id})`;
  } catch (e) {
    if (base.parse_mode) {
      const b2 = { ...base }; delete b2.parse_mode;
      const r = await tg("sendMessage", { ...b2, text });
      return `sent (id: ${r.message_id}) [plain fallback]`;
    }
    throw e;
  }
}

async function doEdit(args) {
  const { chat_id, message_id, text, format } = args;
  if (!chat_id || !message_id || !text) throw new Error("chat_id, message_id, text required");
  const payload = { chat_id, message_id: Number(message_id) };
  payload.text = applyFormat(payload, text, format);
  await tg("editMessageText", payload);
  return `edited (id: ${message_id})`;
}

async function doReact(args) {
  const { chat_id, message_id, emoji } = args;
  if (!chat_id || !message_id || !emoji) throw new Error("chat_id, message_id, emoji required");
  await tg("setMessageReaction", {
    chat_id,
    message_id: Number(message_id),
    reaction: [{ type: "emoji", emoji }],
  });
  return `reacted ${emoji} (id: ${message_id})`;
}

async function doDownload(args) {
  const { file_id } = args;
  if (!file_id) throw new Error("file_id required");
  const f = await tg("getFile", { file_id });
  const res = await fetch(FILE_API(f.file_path));
  const buf = Buffer.from(await res.arrayBuffer());
  const { mkdirSync, writeFileSync } = await import("node:fs");
  mkdirSync(DL_DIR, { recursive: true });
  const out = join(DL_DIR, `${file_id}_${f.file_path.split("/").pop()}`);
  writeFileSync(out, buf);
  return out;
}

const TOOLS = [
  {
    name: "reply",
    description:
      "Reply on Telegram via sendMessage. Pass chat_id from the inbound <channel> tag. " +
      "reply_to (message_id) threads under a message. files (absolute paths) attach images/docs. " +
      "Just write Markdown — it is auto-converted to Telegram HTML (bold, italic, lists, code blocks, tables, blockquotes, links). No need to set format or escape anything.",
    inputSchema: {
      type: "object",
      properties: {
        chat_id: { type: "string" },
        text: { type: "string" },
        reply_to: { type: "string", description: "message_id to thread under" },
        format: { type: "string", enum: ["markdown", "html", "markdownv2", "raw"], description: "default markdown → auto-converted to Telegram HTML. Omit unless you need an opt-out: html (pre-rendered Telegram HTML), markdownv2 (legacy, manual escape), raw (no parse_mode)." },
        files: { type: "array", items: { type: "string" }, description: "absolute file paths" },
      },
      required: ["chat_id"],
    },
    handler: doReply,
  },
  {
    name: "edit_message",
    description: "Edit a previously sent message (interim progress updates; no push notification).",
    inputSchema: {
      type: "object",
      properties: {
        chat_id: { type: "string" },
        message_id: { type: "string" },
        text: { type: "string" },
        format: { type: "string", enum: ["markdown", "html", "markdownv2", "raw"], description: "default markdown → Telegram HTML" },
      },
      required: ["chat_id", "message_id", "text"],
    },
    handler: doEdit,
  },
  {
    name: "react",
    description: "Add an emoji reaction to a message.",
    inputSchema: {
      type: "object",
      properties: {
        chat_id: { type: "string" },
        message_id: { type: "string" },
        emoji: { type: "string" },
      },
      required: ["chat_id", "message_id", "emoji"],
    },
    handler: doReact,
  },
  {
    name: "download_attachment",
    description: "Download a Telegram file by file_id; returns the local absolute path.",
    inputSchema: {
      type: "object",
      properties: { file_id: { type: "string" } },
      required: ["file_id"],
    },
    handler: doDownload,
  },
];

const TOOL_MAP = Object.fromEntries(TOOLS.map((t) => [t.name, t]));

// ---- JSON-RPC stdio 루프 ----

function send(obj) {
  dbg("OUT", obj);
  process.stdout.write(JSON.stringify(obj) + "\n");
}

async function handle(msg) {
  const { id, method, params } = msg;
  const isRequest = id !== undefined && id !== null;

  try {
    switch (method) {
      case "initialize":
        send({
          jsonrpc: "2.0",
          id,
          result: {
            protocolVersion: params?.protocolVersion || "2024-11-05",
            capabilities: { tools: {} },
            serverInfo: { name: "telegram-hulk-reply", version: "1.0.0" },
          },
        });
        return;
      case "notifications/initialized":
        return; // notification, no response
      case "ping":
        if (isRequest) send({ jsonrpc: "2.0", id, result: {} });
        return;
      case "tools/list":
        send({
          jsonrpc: "2.0",
          id,
          result: { tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) },
        });
        return;
      case "tools/call": {
        const tool = TOOL_MAP[params?.name];
        if (!tool) throw new Error(`unknown tool: ${params?.name}`);
        const out = await tool.handler(params.arguments || {});
        send({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: out }] } });
        return;
      }
      default:
        if (isRequest) send({ jsonrpc: "2.0", id, error: { code: -32601, message: `method not found: ${method}` } });
        return;
    }
  } catch (e) {
    log("error:", e.message);
    if (isRequest) {
      // tools/call 오류는 isError content 로 (모델이 보고 재시도)
      if (method === "tools/call") {
        send({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: `ERROR: ${e.message}` }], isError: true } });
      } else {
        send({ jsonrpc: "2.0", id, error: { code: -32603, message: e.message } });
      }
    }
  }
}

if (!TOKEN) {
  log("FATAL: TELEGRAM_BOT_TOKEN not found (env or ../.env)");
  process.exit(1);
}

let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    dbg("IN", line);
    let msg;
    try {
      msg = JSON.parse(line);
    } catch (e) {
      log("parse error:", e.message);
      continue;
    }
    handle(msg);
  }
});
process.stdin.on("end", () => process.exit(0));
log("ready");
