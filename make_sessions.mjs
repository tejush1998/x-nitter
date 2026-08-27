import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const token = process.env.AUTH_TOKEN;
const ct0 = process.env.CT0;

if (!token || !ct0) {
  console.error("AUTH_TOKEN and CT0 must be set (run with: node --env-file=<path>/.env make_sessions.mjs)");
  process.exit(1);
}

const line = JSON.stringify({ kind: "cookie", auth_token: token, ct0, username: "local", id: "1" });
writeFileSync(join(here, "sessions.jsonl"), line + "\n", "utf8");
console.log("wrote sessions.jsonl (1 session)");
