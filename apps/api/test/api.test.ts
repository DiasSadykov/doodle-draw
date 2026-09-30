import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import { createApp } from "../src/app.js";
import { openDb } from "../src/db.js";
import { devVerifier } from "../src/providers.js";
import type { PushedDoodle } from "../src/push.js";

// Smallest thing that starts with the JPEG magic bytes; the API only checks those.
const jpeg = () => new Blob([new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4])], { type: "image/jpeg" });

describe("dev sign-in passphrase", () => {
  it("requires the passphrase prefix when one is set", async () => {
    const verify = devVerifier("s3cret");
    assert.deepEqual(await verify("s3cret:Dias"), { sub: "dias", name: "Dias" });
    await assert.rejects(verify("Dias"));
    await assert.rejects(verify("wrong:Dias"));
    await assert.rejects(verify("s3cret:  "));
  });
});

describe("invite links", () => {
  let app: ReturnType<typeof createApp>;
  const req = (method: string, path: string, opts: { token?: string; ip?: string; body?: unknown } = {}) =>
    app.request(path, {
      method,
      headers: {
        ...(opts.token ? { Authorization: `Bearer ${opts.token}` } : {}),
        ...(opts.ip ? { "X-Forwarded-For": opts.ip } : {}),
        ...(opts.body === undefined ? {} : { "Content-Type": "application/json" }),
      },
      body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
    });
  const signIn = async (name: string) => {
    const res = await req("POST", "/auth", { body: { provider: "dev", token: name } });
    return (await res.json()) as { token: string; user: { id: string; name: string } };
  };

  before(() => {
    app = createApp({
      db: openDb(":memory:"),
      imagesDir: "unused",
      sessionSecret: "test-secret",
      verifiers: { dev: devVerifier() },
      pusher: { notifyDoodle: async () => {} },
      web: { bundleId: "app.doodle.ios", appleTeamId: "TEAM123456" },
    });
  });

  it("serves a public invite page that names the inviter and escapes it", async () => {
    const clara = await signIn(`Clara <b>"x"</b>`);
    const { code } = (await (await req("POST", "/invites", { token: clara.token })).json()) as { code: string };

    const page = await req("GET", `/i/${code.toLowerCase()}`, { ip: "1.1.1.1" });
    assert.equal(page.status, 200);
    const html = await page.text();
    assert.match(html, /invited you to Doodle/);
    assert.match(html, new RegExp(`doodle://invite/${code}`));
    assert.ok(!html.includes("Clara <b>"), "inviter name must be HTML-escaped");
    assert.ok(html.includes("Clara &lt;b&gt;&quot;x&quot;&lt;/b&gt;"));

    const missing = await req("GET", "/i/ZZZZZZ");
    assert.equal(missing.status, 404);
    assert.match(await missing.text(), /no longer valid/);
  });

  it("tells the signed-in user who invited them, and why not when it can't work", async () => {
    const dias = await signIn("Dias");
    const aruzhan = await signIn("Aruzhan");
    const { code } = (await (await req("POST", "/invites", { token: dias.token })).json()) as { code: string };

    assert.deepEqual(await (await req("GET", `/invites/${code}`, { token: aruzhan.token })).json(), {
      inviter: dias.user,
    });
    assert.equal((await req("GET", `/invites/${code}`, { token: dias.token })).status, 400); // own
    assert.equal((await req("GET", "/invites/NOPE22", { token: aruzhan.token })).status, 404);
    assert.equal((await req("GET", `/invites/${code}`)).status, 401);
  });

  it("matches a fresh install to the link that device just opened, once", async () => {
    const maya = await signIn("Maya");
    const ben = await signIn("Ben");
    const { code } = (await (await req("POST", "/invites", { token: maya.token })).json()) as { code: string };

    await req("GET", `/i/${code}`, { ip: "9.9.9.9" });

    // A different network sees nothing.
    assert.equal((await req("POST", "/invites/claim", { token: ben.token, ip: "8.8.8.8" })).status, 404);

    const claimed = await req("POST", "/invites/claim", { token: ben.token, ip: "9.9.9.9" });
    assert.equal(claimed.status, 200);
    assert.deepEqual(await claimed.json(), { code, inviter: maya.user });

    // Single use: declining must not cause a re-prompt.
    assert.equal((await req("POST", "/invites/claim", { token: ben.token, ip: "9.9.9.9" })).status, 404);
  });

  it("ignores links whose inviter got paired in the meantime", async () => {
    const [a, b, c] = await Promise.all([signIn("A1"), signIn("B1"), signIn("C1")]);
    const { code } = (await (await req("POST", "/invites", { token: a.token })).json()) as { code: string };
    await req("GET", `/i/${code}`, { ip: "7.7.7.7" });
    assert.equal((await req("POST", "/pair", { token: b.token, body: { code } })).status, 200);
    assert.equal((await req("POST", "/invites/claim", { token: c.token, ip: "7.7.7.7" })).status, 404);
  });

  it("publishes the universal-link file only when a team id is configured", async () => {
    const res = await req("GET", "/.well-known/apple-app-site-association");
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), {
      applinks: { details: [{ appIDs: ["TEAM123456.app.doodle.ios"], components: [{ "/": "/i/*" }] }] },
    });
  });
});

describe("doodle api", () => {
  let dir: string;
  let app: ReturnType<typeof createApp>;
  const pushes: PushedDoodle[] = [];

  before(async () => {
    dir = await mkdtemp(join(tmpdir(), "doodle-api-"));
    app = createApp({
      db: openDb(":memory:"),
      imagesDir: join(dir, "images"),
      sessionSecret: "test-secret",
      verifiers: { dev: devVerifier() },
      pusher: { notifyDoodle: async (_device, doodle) => void pushes.push(doodle) },
    });
  });
  after(() => rm(dir, { recursive: true, force: true }));

  const call = (method: string, path: string, token?: string, body?: unknown) =>
    app.request(path, {
      method,
      headers: {
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(body === undefined ? {} : { "Content-Type": "application/json" }),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });

  const signIn = async (name: string) => {
    const res = await call("POST", "/auth", undefined, { provider: "dev", token: name });
    assert.equal(res.status, 200);
    return (await res.json()) as { token: string; user: { id: string; name: string } };
  };

  const upload = (token: string, hasPhoto = false) => {
    const form = new FormData();
    form.set("image", jpeg(), "doodle.jpg");
    form.set("hasPhoto", String(hasPhoto));
    return app.request("/doodles", { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: form });
  };

  let dias: Awaited<ReturnType<typeof signIn>>;
  let aruzhan: Awaited<ReturnType<typeof signIn>>;

  it("rejects requests without a session and unknown providers", async () => {
    assert.equal((await call("GET", "/me")).status, 401);
    assert.equal((await call("GET", "/me", "garbage")).status, 401);
    const res = await call("POST", "/auth", undefined, { provider: "myspace", token: "x" });
    assert.equal(res.status, 400);
    assert.deepEqual(await res.json(), { error: "unsupported_provider" });
  });

  it("signs in and is idempotent per provider identity", async () => {
    dias = await signIn("Dias");
    aruzhan = await signIn("Aruzhan");
    assert.equal((await signIn("Dias")).user.id, dias.user.id);

    const me = await (await call("GET", "/me", dias.token)).json();
    assert.deepEqual(me, { user: dias.user, partner: null });
  });

  it("blocks doodles until paired", async () => {
    assert.equal((await upload(dias.token)).status, 409);
    assert.deepEqual(await (await call("GET", "/doodles", dias.token)).json(), []);
  });

  it("pairs through an invite code", async () => {
    const invite = (await (await call("POST", "/invites", dias.token)).json()) as { code: string };
    assert.match(invite.code, /^[A-HJ-NP-Z2-9]{6}$/);

    const own = await call("POST", "/pair", dias.token, { code: invite.code });
    assert.deepEqual(await own.json(), { error: "own_invite" });
    const wrong = await call("POST", "/pair", aruzhan.token, { code: "ZZZZZZ" });
    assert.equal(wrong.status, 404);

    // Lowercase + whitespace is forgiven.
    const ok = await call("POST", "/pair", aruzhan.token, { code: ` ${invite.code.toLowerCase()} ` });
    assert.equal(ok.status, 200);
    assert.deepEqual(await ok.json(), { partner: dias.user });

    assert.deepEqual(await (await call("GET", "/me", dias.token)).json(), { user: dias.user, partner: aruzhan.user });
    // The code is single use.
    assert.equal((await call("POST", "/pair", aruzhan.token, { code: invite.code })).status, 409);
    assert.equal((await call("POST", "/invites", dias.token)).status, 409);
  });

  it("sends a doodle, pushes the partner, and serves it to both sides", async () => {
    assert.equal((await call("PUT", "/device", aruzhan.token, { apnsToken: "abc" })).status, 204);

    const res = await upload(dias.token, true);
    assert.equal(res.status, 201);
    const doodle = (await res.json()) as { id: string; from: string; hasPhoto: boolean; createdAt: string };
    assert.equal(doodle.from, "you");
    assert.equal(doodle.hasPhoto, true);
    assert.equal(pushes.at(-1)?.id, doodle.id);
    assert.equal(pushes.at(-1)?.senderName, "Dias");

    const theirs = (await (await call("GET", "/doodles", aruzhan.token)).json()) as (typeof doodle)[];
    assert.equal(theirs.length, 1);
    assert.equal(theirs[0]?.from, "partner");

    const img = await call("GET", `/doodles/${doodle.id}/image`, aruzhan.token);
    assert.equal(img.status, 200);
    assert.equal(img.headers.get("Content-Type"), "image/jpeg");
    assert.deepEqual([...new Uint8Array(await img.arrayBuffer()).slice(0, 4)], [0xff, 0xd8, 0xff, 0xe0]);
  });

  it("validates uploads and paginates history", async () => {
    const notJpeg = new FormData();
    notJpeg.set("image", new Blob([new Uint8Array([1, 2, 3, 4])]), "x.png");
    const bad = await app.request("/doodles", {
      method: "POST",
      headers: { Authorization: `Bearer ${dias.token}` },
      body: notJpeg,
    });
    assert.equal(bad.status, 415);
    assert.equal((await app.request("/doodles", { method: "POST", headers: { Authorization: `Bearer ${dias.token}` }, body: new FormData() })).status, 400);

    await new Promise((r) => setTimeout(r, 5));
    await upload(aruzhan.token);
    const page1 = (await (await call("GET", "/doodles?limit=1", dias.token)).json()) as { id: string; from: string; createdAt: string }[];
    assert.equal(page1.length, 1);
    assert.equal(page1[0]?.from, "partner"); // newest first
    const page2 = (await (await call("GET", `/doodles?limit=1&before=${page1[0]!.createdAt}`, dias.token)).json()) as unknown[];
    assert.equal(page2.length, 1);
    assert.equal((await call("GET", "/doodles?before=nope", dias.token)).status, 400);
  });

  it("keeps strangers out of a pair's images", async () => {
    const stranger = await signIn("Mallory");
    const [first] = (await (await call("GET", "/doodles", dias.token)).json()) as { id: string }[];
    assert.equal((await call("GET", `/doodles/${first!.id}/image`, stranger.token)).status, 404);
  });

  it("unpairs and deletes the shared doodles", async () => {
    const [first] = (await (await call("GET", "/doodles", dias.token)).json()) as { id: string }[];
    assert.equal((await call("DELETE", "/pair", dias.token)).status, 204);
    assert.deepEqual(await (await call("GET", "/me", aruzhan.token)).json(), { user: aruzhan.user, partner: null });
    assert.deepEqual(await (await call("GET", "/doodles", dias.token)).json(), []);
    assert.equal((await call("GET", `/doodles/${first!.id}/image`, aruzhan.token)).status, 404);
    assert.equal((await call("DELETE", "/pair", dias.token)).status, 204); // idempotent
  });
});
