import { serve } from "@hono/node-server";
import { join } from "node:path";
import { createApp } from "./app.js";
import { openDb } from "./db.js";
import { devVerifier, googleVerifier, type Verifier } from "./providers.js";
import { logPusher } from "./push.js";

const devKey = process.env.DEV_AUTH_KEY || undefined;
const devAuth = process.env.DEV_AUTH === "1" || devKey !== undefined;
const dataDir = process.env.DATA_DIR ?? "./data";
const port = Number(process.env.PORT ?? 8787);
const googleClientId = process.env.GOOGLE_CLIENT_ID;

const sessionSecret = process.env.SESSION_SECRET ?? (devAuth ? "dev-only-secret-change-me" : "");
if (!sessionSecret) {
  console.error("SESSION_SECRET is required (try: openssl rand -hex 32)");
  process.exit(1);
}

const verifiers: Record<string, Verifier> = {};
if (googleClientId) verifiers.google = googleVerifier(googleClientId);
if (devAuth) verifiers.dev = devVerifier(devKey);
if (Object.keys(verifiers).length === 0) {
  console.error("No sign-in method enabled: set GOOGLE_CLIENT_ID (or DEV_AUTH=1 for local testing)");
  process.exit(1);
}

const app = createApp({
  db: openDb(join(dataDir, "doodle.db")),
  imagesDir: join(dataDir, "images"),
  sessionSecret,
  verifiers,
  pusher: logPusher,
  web: {
    bundleId: process.env.BUNDLE_ID ?? "app.doodle.ios",
    appleTeamId: process.env.APPLE_TEAM_ID || undefined,
    appStoreUrl: process.env.APP_STORE_URL || undefined,
  },
});

serve({ fetch: app.fetch, port }, (info) => {
  console.log(`doodle-api listening on :${info.port} (sign-in: ${Object.keys(verifiers).join(", ")})`);
});
