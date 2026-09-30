import { serve } from "@hono/node-server";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createApp } from "./app.js";
import { openDb } from "./db.js";
import { appleVerifier, devVerifier, googleVerifier, type Verifier } from "./providers.js";
import { apnsPusher, logPusher, type Pusher } from "./push.js";

const devKey = process.env.DEV_AUTH_KEY || undefined;
const devAuth = process.env.DEV_AUTH === "1" || devKey !== undefined;
const dataDir = process.env.DATA_DIR ?? "./data";
const port = Number(process.env.PORT ?? 8787);
const googleClientId = process.env.GOOGLE_CLIENT_ID;
const bundleId = process.env.BUNDLE_ID ?? "app.doodle.ios";
const appleTeamId = process.env.APPLE_TEAM_ID || undefined;
const apnsKeyPath = process.env.APNS_KEY_PATH || undefined;
const apnsKeyId = process.env.APNS_KEY_ID || undefined;

const sessionSecret = process.env.SESSION_SECRET ?? (devAuth ? "dev-only-secret-change-me" : "");
if (!sessionSecret) {
  console.error("SESSION_SECRET is required (try: openssl rand -hex 32)");
  process.exit(1);
}

const verifiers: Record<string, Verifier> = {};
if (googleClientId) verifiers.google = googleVerifier(googleClientId);
// Sign in with Apple needs the paid developer account, so it switches on together with the team id.
if (appleTeamId) verifiers.apple = appleVerifier(bundleId);
if (devAuth) verifiers.dev = devVerifier(devKey);
if (Object.keys(verifiers).length === 0) {
  console.error("No sign-in method enabled: set APPLE_TEAM_ID, GOOGLE_CLIENT_ID (or DEV_AUTH=1 for local testing)");
  process.exit(1);
}

const db = openDb(join(dataDir, "doodle.db"));

let pusher: Pusher = logPusher;
if (appleTeamId && apnsKeyPath && apnsKeyId) {
  pusher = apnsPusher({
    teamId: appleTeamId,
    keyId: apnsKeyId,
    privateKeyPem: readFileSync(apnsKeyPath, "utf8"),
    bundleId,
    // Apple says the device is gone (app deleted): stop sending to it.
    onUnregistered: (token) => {
      db.prepare("DELETE FROM devices WHERE apns_token = ?").run(token);
      db.prepare("UPDATE devices SET widget_token = NULL WHERE widget_token = ?").run(token);
    },
  });
} else if (apnsKeyPath || apnsKeyId) {
  console.error("APNs needs APPLE_TEAM_ID, APNS_KEY_ID and APNS_KEY_PATH together; push is off.");
}

const app = createApp({
  db,
  imagesDir: join(dataDir, "images"),
  sessionSecret,
  verifiers,
  pusher,
  web: {
    bundleId,
    appleTeamId,
    appStoreUrl: process.env.APP_STORE_URL || undefined,
  },
});

serve({ fetch: app.fetch, port }, (info) => {
  const push = pusher === logPusher ? "off" : "on";
  console.log(`doodle-api listening on :${info.port} (sign-in: ${Object.keys(verifiers).join(", ")}; push: ${push})`);
});
