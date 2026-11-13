// Tangram WhatsApp 桥接进程 —— OpenClaw 同款方案：Baileys（WhatsApp Web 多设备协议）
// 职责：
//  1) 未登录时生成真实配对二维码（QR PNG 落盘，供 IM 网关 /api/login/whatsapp/qr 读取）
//  2) 收到消息 -> POST 到 Tangram IM 网关 webhook（入站规范化、风控、Agent 回复）
//  3) 暴露本地 HTTP 出站接口 POST /send {to, text}（网关风控通过后回调下发）
// 仅监听 127.0.0.1；会话凭据保存在 --auth 目录（等价 OpenClaw 的 per-channel 凭据隔离）。
import makeWASocket, {
  useMultiFileAuthState,
  fetchLatestBaileysVersion,
  DisconnectReason,
} from "@whiskeysockets/baileys";
import * as qrcode from "qrcode";
import express from "express";
import { mkdirSync, writeFileSync, existsSync, rmSync } from "node:fs";

const ARGS = process.argv.slice(2);
const arg = (name, dft) => {
  const i = ARGS.indexOf(`--${name}`);
  return i >= 0 ? ARGS[i + 1] : dft;
};
const AUTH_DIR = arg("auth", "/root/wa-bridge/session");
const GATEWAY = arg("gateway", "http://127.0.0.1:50432/webhook/whatsapp");
const PORT = Number(arg("port", 50433));
const QR_PATH = arg("qr", "/root/wa-bridge/whatsapp_qr.png");

mkdirSync(AUTH_DIR, { recursive: true });
try { rmSync(QR_PATH + ".online"); } catch {}

async function post(url, body) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return { status: res.status, text: await res.text() };
}

let sock;
async function connect() {
  const { state, saveCreds } = await useMultiFileAuthState(AUTH_DIR);
  const { version } = await fetchLatestBaileysVersion();
  sock = makeWASocket({
    version,
    auth: state,
    printQRInTerminal: false,
    browser: ["Tangram", "Chrome", "1.0.0"],
  });

  sock.ev.on("connection.update", async (u) => {
    const { connection, qr } = u;
    if (qr) {
      try {
        await qrcode.toFile(QR_PATH, qr, { width: 320, margin: 2 });
        console.log(`[wa] QR 已刷新: ${QR_PATH}`);
      } catch (e) {
        console.log("[wa] QR 落盘失败", e.message);
      }
    }
    if (connection === "open") {
      console.log("[wa] 已登录（WhatsApp 连接建立）");
      try { writeFileSync(QR_PATH + ".online", String(sock.user?.id || "")); } catch {}
    } else if (connection === "close") {
      const code = u?.lastError?.data?.details?.status?.[0]?.reason;
      const loggedOut = code === DisconnectReason.loggedOut;
      console.log(`[wa] 连接关闭 reason=${code} loggedOut=${loggedOut}`);
      if (!loggedOut) setTimeout(connect, 3000); // 断线重连，等价 OpenClaw channel supervisor
    }
  });

  sock.ev.on("creds.update", saveCreds);

  sock.ev.on("messages.upsert", async ({ messages, type }) => {
    if (type !== "notify") return;
    for (const m of messages) {
      if (m.key?.fromMe) continue;
      const chatJid = m.key?.remoteJid || "";
      if (chatJid.endsWith("@status")) continue;
      const text =
        m.message?.conversation ||
        m.message?.extendedTextMessage?.text ||
        m.message?.imageMessage?.caption ||
        "";
      try {
        const r = await post(GATEWAY, {
          user_id: chatJid,
          message_id: m.key?.id,
          text,
          has_image: Boolean(m.message?.imageMessage),
          timestamp: (m.messageTimestamp || 0) * 1,
        });
        console.log(`[wa] inbound -> gateway ${r.status} user=${chatJid} text=${text.slice(0, 40)}`);
      } catch (e) {
        console.log("[wa] 入站推送失败:", e.message);
      }
    }
  });
}

await connect();

const app = express();
app.use(express.json());
app.get("/status", (_req, res) => {
  res.json({ online: existsSync(QR_PATH + ".online"), qr_path: QR_PATH, has_qr: existsSync(QR_PATH) });
});
app.post("/send", async (req, res) => {
  const { to, text } = req.body || {};
  if (!to || !text) return res.status(400).json({ error: "to/text required" });
  try {
    await sock.sendMessage(to, { text: String(text) });
    res.json({ ok: true });
  } catch (e) {
    res.status(502).json({ ok: false, error: e.message });
  }
});
app.listen(PORT, "127.0.0.1", () => console.log(`[wa] bridge http://127.0.0.1:${PORT}`));
