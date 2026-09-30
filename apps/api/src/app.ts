import { Hono, type Context } from "hono";
import { bodyLimit } from "hono/body-limit";
import { createHmac, randomInt, randomUUID } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { DatabaseSync } from "node:sqlite";
import type { Verifier } from "./providers.js";
import type { Pusher } from "./push.js";
import { signSession, verifySession } from "./session.js";
import { appSiteAssociation, invitePage, type WebConfig } from "./web.js";

export type Deps = {
  db: DatabaseSync;
  imagesDir: string;
  sessionSecret: string;
  /** Keyed by provider name: "google", "dev", later "apple". */
  verifiers: Record<string, Verifier>;
  pusher: Pusher;
  /** Invite link page + universal links. Defaults are fine for tests. */
  web?: WebConfig;
};

type UserRow = { id: string; name: string };
type PairRow = { id: string; user_a: string; user_b: string };
type DoodleRow = { id: string; sender_id: string; has_photo: number; created_at: string };

const INVITE_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const VISIT_TTL_MS = 60 * 60 * 1000; // how long an opened link can be matched to a new install
const INVITE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no 0/O/1/I
const MAX_IMAGE_BYTES = 2 * 1024 * 1024;

class ApiError extends Error {
  constructor(
    readonly status: 400 | 401 | 404 | 409 | 410 | 413 | 415,
    readonly code: string,
  ) {
    super(code);
  }
}

const normalizeCode = (raw: string) => raw.trim().toUpperCase();

export function createApp({
  db,
  imagesDir,
  sessionSecret,
  verifiers,
  pusher,
  web = { bundleId: "app.doodle.ios" },
}: Deps) {
  const app = new Hono<{ Variables: { userId: string } }>();

  // ---- tiny SQL helpers -------------------------------------------------
  type Param = string | number | null;
  const get = <T>(sql: string, ...p: Param[]) => db.prepare(sql).get(...p) as unknown as T | undefined;
  const all = <T>(sql: string, ...p: Param[]) => db.prepare(sql).all(...p) as unknown as T[];
  const run = (sql: string, ...p: Param[]) => void db.prepare(sql).run(...p);
  const tx = <T>(fn: () => T): T => {
    db.exec("BEGIN IMMEDIATE");
    try {
      const result = fn();
      db.exec("COMMIT");
      return result;
    } catch (e) {
      db.exec("ROLLBACK");
      throw e;
    }
  };

  const pairOf = (userId: string) =>
    get<PairRow>("SELECT id, user_a, user_b FROM pairs WHERE user_a = ? OR user_b = ?", userId, userId);
  const partnerOf = (pair: PairRow, userId: string) =>
    get<UserRow>("SELECT id, name FROM users WHERE id = ?", pair.user_a === userId ? pair.user_b : pair.user_a);
  const imagePath = (id: string) => join(imagesDir, `${id}.jpg`);

  const toDoodle = (row: DoodleRow, me: string) => ({
    id: row.id,
    from: row.sender_id === me ? "you" : "partner",
    hasPhoto: row.has_photo === 1,
    createdAt: row.created_at,
  });

  async function readJson(c: Context): Promise<Record<string, unknown>> {
    try {
      const body = await c.req.json();
      if (body && typeof body === "object" && !Array.isArray(body)) return body as Record<string, unknown>;
    } catch {
      /* fall through */
    }
    throw new ApiError(400, "bad_request");
  }

  // ---- errors + auth ----------------------------------------------------
  app.onError((err, c) => {
    if (err instanceof ApiError) return c.json({ error: err.code }, err.status);
    console.error(err);
    return c.json({ error: "internal" }, 500);
  });

  // Public: sign-in, and the web side of invite links.
  const isPublic = (method: string, path: string) =>
    (method === "POST" && path === "/auth") ||
    (method === "GET" && (path.startsWith("/i/") || path === "/.well-known/apple-app-site-association"));

  app.use("*", async (c, next) => {
    if (isPublic(c.req.method, c.req.path)) return next();
    const header = c.req.header("Authorization") ?? "";
    const token = header.startsWith("Bearer ") ? header.slice(7) : "";
    const userId = token ? await verifySession(token, sessionSecret) : null;
    if (!userId || !get<UserRow>("SELECT id, name FROM users WHERE id = ?", userId)) {
      throw new ApiError(401, "unauthorized");
    }
    c.set("userId", userId);
    await next();
  });

  // ---- invite links (public web) ---------------------------------------
  // Caddy is the only way in (the api port is not published), so X-Forwarded-For is the real client.
  const ipHash = (c: Context) => {
    const ip = c.req.header("x-forwarded-for")?.split(",")[0]?.trim();
    return ip ? createHmac("sha256", sessionSecret).update(ip).digest("hex") : null;
  };

  app.get("/i/:code", (c) => {
    const code = normalizeCode(c.req.param("code"));
    const invite = get<{ user_id: string; expires_at: string }>(
      "SELECT user_id, expires_at FROM invites WHERE code = ?",
      code,
    );
    const inviter =
      invite && invite.expires_at >= new Date().toISOString()
        ? get<UserRow>("SELECT id, name FROM users WHERE id = ?", invite.user_id)
        : undefined;

    const hash = ipHash(c);
    if (inviter && hash) {
      run("INSERT INTO invite_visits (ip_hash, code, created_at) VALUES (?, ?, ?)", hash, code, new Date().toISOString());
    }
    return c.html(invitePage({ code, inviter: inviter?.name ?? null, config: web }), inviter ? 200 : 404, {
      "Cache-Control": "no-store",
    });
  });

  app.get("/.well-known/apple-app-site-association", (c) => {
    if (!web.appleTeamId) return c.body(null, 404);
    return c.json(appSiteAssociation(web));
  });

  // ---- auth -------------------------------------------------------------
  app.post("/auth", async (c) => {
    const body = await readJson(c);
    const provider = typeof body.provider === "string" ? body.provider : "";
    const token = typeof body.token === "string" ? body.token : "";
    if (!Object.hasOwn(verifiers, provider)) throw new ApiError(400, "unsupported_provider");

    let identity;
    try {
      identity = await verifiers[provider]!(token, { name: typeof body.name === "string" ? body.name : undefined });
    } catch {
      throw new ApiError(401, "invalid_token");
    }

    let user = get<UserRow>(
      "SELECT id, name FROM users WHERE provider = ? AND provider_sub = ?",
      provider,
      identity.sub,
    );
    if (!user) {
      user = { id: randomUUID(), name: identity.name };
      run(
        "INSERT INTO users (id, provider, provider_sub, name, created_at) VALUES (?, ?, ?, ?, ?)",
        user.id,
        provider,
        identity.sub,
        user.name,
        new Date().toISOString(),
      );
    }
    return c.json({ token: await signSession(user.id, sessionSecret), user });
  });

  app.get("/me", (c) => {
    const me = c.get("userId");
    const user = get<UserRow>("SELECT id, name FROM users WHERE id = ?", me)!;
    const pair = pairOf(me);
    return c.json({ user, partner: pair ? (partnerOf(pair, me) ?? null) : null });
  });

  // ---- pairing ----------------------------------------------------------
  app.post("/invites", (c) => {
    const me = c.get("userId");
    if (pairOf(me)) throw new ApiError(409, "already_paired");

    const expiresAt = new Date(Date.now() + INVITE_TTL_MS).toISOString();
    const code = tx(() => {
      run("DELETE FROM invites WHERE user_id = ?", me);
      for (let attempt = 0; attempt < 10; attempt++) {
        const candidate = Array.from({ length: 6 }, () => INVITE_ALPHABET[randomInt(INVITE_ALPHABET.length)]).join("");
        if (!get("SELECT 1 FROM invites WHERE code = ?", candidate)) {
          run("INSERT INTO invites (code, user_id, expires_at) VALUES (?, ?, ?)", candidate, me, expiresAt);
          return candidate;
        }
      }
      throw new Error("could not generate a unique invite code");
    });
    return c.json({ code, expiresAt }, 201);
  });

  /** Who is behind this invite, or why it can't be used by `me`. */
  const inviterFor = (rawCode: string, me: string): UserRow => {
    const code = normalizeCode(rawCode);
    const invite = get<{ user_id: string; expires_at: string }>(
      "SELECT user_id, expires_at FROM invites WHERE code = ?",
      code,
    );
    if (!invite) throw new ApiError(404, "invite_not_found");
    if (invite.expires_at < new Date().toISOString()) throw new ApiError(410, "invite_expired");
    if (invite.user_id === me) throw new ApiError(400, "own_invite");
    if (pairOf(me)) throw new ApiError(409, "already_paired");
    const inviter = get<UserRow>("SELECT id, name FROM users WHERE id = ?", invite.user_id);
    if (!inviter || pairOf(inviter.id)) throw new ApiError(404, "invite_not_found");
    return inviter;
  };

  // Lets the app say "Dias invited you" before the user accepts.
  app.get("/invites/:code", (c) => c.json({ inviter: inviterFor(c.req.param("code"), c.get("userId")) }));

  // A new install asks: did this device just open an invite link? Matched by IP within an hour.
  // Answers at most once per link visit, so declining doesn't cause a re-prompt.
  app.post("/invites/claim", (c) => {
    const me = c.get("userId");
    const hash = ipHash(c);
    if (!hash) throw new ApiError(404, "invite_not_found");

    run("DELETE FROM invite_visits WHERE created_at < ?", new Date(Date.now() - VISIT_TTL_MS).toISOString());
    const visits = all<{ code: string }>(
      "SELECT code FROM invite_visits WHERE ip_hash = ? ORDER BY created_at DESC",
      hash,
    );
    run("DELETE FROM invite_visits WHERE ip_hash = ?", hash);

    for (const { code } of visits) {
      try {
        return c.json({ code, inviter: inviterFor(code, me) });
      } catch (e) {
        if (!(e instanceof ApiError)) throw e;
      }
    }
    throw new ApiError(404, "invite_not_found");
  });

  app.post("/pair", async (c) => {
    const me = c.get("userId");
    const body = await readJson(c);
    const code = typeof body.code === "string" ? body.code.trim().toUpperCase() : "";

    const partner = tx(() => {
      if (pairOf(me)) throw new ApiError(409, "already_paired");
      const invite = get<{ user_id: string; expires_at: string }>(
        "SELECT user_id, expires_at FROM invites WHERE code = ?",
        code,
      );
      if (!invite) throw new ApiError(404, "invite_not_found");
      if (invite.expires_at < new Date().toISOString()) {
        run("DELETE FROM invites WHERE code = ?", code);
        throw new ApiError(410, "invite_expired");
      }
      if (invite.user_id === me) throw new ApiError(400, "own_invite");
      if (pairOf(invite.user_id)) throw new ApiError(404, "invite_not_found");

      run(
        "INSERT INTO pairs (id, user_a, user_b, created_at) VALUES (?, ?, ?, ?)",
        randomUUID(),
        invite.user_id,
        me,
        new Date().toISOString(),
      );
      run("DELETE FROM invites WHERE user_id IN (?, ?)", me, invite.user_id);
      return get<UserRow>("SELECT id, name FROM users WHERE id = ?", invite.user_id)!;
    });
    return c.json({ partner });
  });

  app.delete("/pair", async (c) => {
    const me = c.get("userId");
    const pair = pairOf(me);
    if (pair) {
      const ids = all<{ id: string }>("SELECT id FROM doodles WHERE pair_id = ?", pair.id).map((r) => r.id);
      tx(() => {
        run("DELETE FROM doodles WHERE pair_id = ?", pair.id);
        run("DELETE FROM pairs WHERE id = ?", pair.id);
      });
      await Promise.all(ids.map((id) => rm(imagePath(id), { force: true })));
    }
    return c.body(null, 204);
  });

  // ---- device -----------------------------------------------------------
  app.put("/device", async (c) => {
    const body = await readJson(c);
    const apnsToken = typeof body.apnsToken === "string" ? body.apnsToken : "";
    const widgetToken = typeof body.widgetToken === "string" ? body.widgetToken : null;
    // Push tokens are hex strings; anything else is a bug or an attack.
    const isHex = (s: string) => /^[0-9a-fA-F]{1,512}$/.test(s);
    if (!isHex(apnsToken) || (widgetToken !== null && !isHex(widgetToken))) throw new ApiError(400, "bad_request");
    run(
      `INSERT INTO devices (user_id, apns_token, widget_token, apns_sandbox) VALUES (?, ?, ?, ?)
       ON CONFLICT (user_id) DO UPDATE SET apns_token = excluded.apns_token,
         widget_token = excluded.widget_token, apns_sandbox = excluded.apns_sandbox`,
      c.get("userId"),
      apnsToken,
      widgetToken,
      body.sandbox === true ? 1 : 0,
    );
    return c.body(null, 204);
  });

  // ---- doodles ----------------------------------------------------------
  app.post(
    "/doodles",
    bodyLimit({
      maxSize: MAX_IMAGE_BYTES + 64 * 1024, // image + multipart overhead
      onError: (c) => c.json({ error: "too_large" }, 413),
    }),
    async (c) => {
      const me = c.get("userId");
      const pair = pairOf(me);
      if (!pair) throw new ApiError(409, "not_paired");

      let form;
      try {
        form = await c.req.parseBody();
      } catch {
        throw new ApiError(400, "bad_request");
      }
      const image = form["image"];
      if (!(image instanceof File)) throw new ApiError(400, "image_required");
      if (image.size > MAX_IMAGE_BYTES) throw new ApiError(413, "too_large");
      const bytes = new Uint8Array(await image.arrayBuffer());
      if (!(bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff)) throw new ApiError(415, "not_jpeg");

      const row: DoodleRow = {
        id: randomUUID(),
        sender_id: me,
        has_photo: form["hasPhoto"] === "true" || form["hasPhoto"] === "1" ? 1 : 0,
        created_at: new Date().toISOString(),
      };
      await mkdir(imagesDir, { recursive: true });
      await writeFile(imagePath(row.id), bytes);
      run(
        "INSERT INTO doodles (id, pair_id, sender_id, has_photo, created_at) VALUES (?, ?, ?, ?, ?)",
        row.id,
        pair.id,
        me,
        row.has_photo,
        row.created_at,
      );

      // Best effort: a failed push must never fail the upload.
      const partnerId = pair.user_a === me ? pair.user_b : pair.user_a;
      const device = get<{ apns_token: string; widget_token: string | null; apns_sandbox: number }>(
        "SELECT apns_token, widget_token, apns_sandbox FROM devices WHERE user_id = ?",
        partnerId,
      );
      const sender = get<UserRow>("SELECT id, name FROM users WHERE id = ?", me)!;
      pusher
        .notifyDoodle(
          device && { apnsToken: device.apns_token, widgetToken: device.widget_token, sandbox: device.apns_sandbox === 1 },
          { id: row.id, senderName: sender.name, createdAt: row.created_at },
        )
        .catch((e) => console.error("push failed", e));

      return c.json(toDoodle(row, me), 201);
    },
  );

  app.get("/doodles", (c) => {
    const me = c.get("userId");
    const pair = pairOf(me);
    if (!pair) return c.json([]);

    const before = c.req.query("before") ?? "9999-12-31T23:59:59.999Z";
    if (Number.isNaN(Date.parse(before))) throw new ApiError(400, "bad_request");
    const limit = Math.min(Math.max(Number.parseInt(c.req.query("limit") ?? "20", 10) || 20, 1), 50);

    const rows = all<DoodleRow>(
      `SELECT id, sender_id, has_photo, created_at FROM doodles
       WHERE pair_id = ? AND created_at < ? ORDER BY created_at DESC LIMIT ?`,
      pair.id,
      before,
      limit,
    );
    return c.json(rows.map((r) => toDoodle(r, me)));
  });

  app.get("/doodles/:id/image", async (c) => {
    const pair = pairOf(c.get("userId"));
    const id = c.req.param("id");
    if (!pair || !get("SELECT 1 FROM doodles WHERE id = ? AND pair_id = ?", id, pair.id)) {
      throw new ApiError(404, "not_found");
    }
    let bytes: Buffer;
    try {
      bytes = await readFile(imagePath(id));
    } catch {
      throw new ApiError(404, "not_found");
    }
    return c.body(new Uint8Array(bytes), 200, {
      "Content-Type": "image/jpeg",
      "Cache-Control": "private, max-age=31536000, immutable",
    });
  });

  return app;
}
