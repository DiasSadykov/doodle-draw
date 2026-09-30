import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import { generateKeyPairSync } from "node:crypto";
import { createLocalJWKSet, exportJWK, generateKeyPair, jwtVerify, SignJWT } from "jose";
import { createApp } from "../src/app.js";
import { openDb } from "../src/db.js";
import { appleVerifier, devVerifier } from "../src/providers.js";
import { apnsPusher, type ApnsRequest, type ApnsResponse, type PushedDoodle } from "../src/push.js";

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

describe("sign in with apple", () => {
  const bundleId = "app.doodle.ios";
  const setup = async () => {
    const { publicKey, privateKey } = await generateKeyPair("RS256");
    const jwk = { ...(await exportJWK(publicKey)), kid: "k1", alg: "RS256" };
    const sign = (claims: { iss?: string; aud?: string; sub?: string }) =>
      new SignJWT({})
        .setProtectedHeader({ alg: "RS256", kid: "k1" })
        .setIssuer(claims.iss ?? "https://appleid.apple.com")
        .setAudience(claims.aud ?? bundleId)
        .setSubject(claims.sub ?? "001234.abcd")
        .setIssuedAt()
        .setExpirationTime("10m")
        .sign(privateKey);
    return { verify: appleVerifier(bundleId, createLocalJWKSet({ keys: [jwk] })), sign };
  };

  it("accepts a valid token and uses the name the app passes along", async () => {
    const { verify, sign } = await setup();
    assert.deepEqual(await verify(await sign({}), { name: "  Clara Cao " }), { sub: "001234.abcd", name: "Clara Cao" });
    assert.deepEqual(await verify(await sign({})), { sub: "001234.abcd", name: "Friend" });
  });

  it("rejects tokens for another app, another issuer, or signed by someone else", async () => {
    const { verify, sign } = await setup();
    await assert.rejects(verify(await sign({ aud: "com.evil.app" })));
    await assert.rejects(verify(await sign({ iss: "https://evil.example" })));
    const other = await setup(); // different key pair
    await assert.rejects(verify(await other.sign({})));
    await assert.rejects(verify("not-a-jwt"));
  });
});

describe("apns pusher", () => {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const pem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();
  const doodle = { id: "d1", senderName: "Dias", createdAt: "2026-01-01T00:00:00.000Z" };

  const make = (respond: (req: ApnsRequest) => ApnsResponse = () => ({ status: 200, body: "" })) => {
    const sent: ApnsRequest[] = [];
    const dead: string[] = [];
    const pusher = apnsPusher({
      teamId: "TEAM123456",
      keyId: "KEY1234567",
      privateKeyPem: pem,
      bundleId: "app.doodle.ios",
      transport: async (req) => (sent.push(req), respond(req)),
      onUnregistered: (t) => dead.push(t),
    });
    return { pusher, sent, dead };
  };

  it("sends an alert and a widget push, signed with the team key", async () => {
    const { pusher, sent } = make();
    await pusher.notifyDoodle({ apnsToken: "abc123", widgetToken: "def456", sandbox: true }, doodle);
    assert.equal(sent.length, 2);

    const alert = sent.find((r) => r.token === "abc123")!;
    assert.equal(alert.sandbox, true);
    assert.equal(alert.headers["apns-topic"], "app.doodle.ios");
    assert.equal(alert.headers["apns-push-type"], "alert");
    assert.deepEqual(JSON.parse(alert.body).aps.alert, { title: "Dias", body: "sent you a doodle" });

    const widget = sent.find((r) => r.token === "def456")!;
    assert.equal(widget.headers["apns-topic"], "app.doodle.ios.push-type.widgets");
    assert.equal(widget.headers["apns-push-type"], "widgets");
    assert.deepEqual(JSON.parse(widget.body), { aps: { "content-changed": true } });

    const jwt = alert.headers["authorization"]!.replace("bearer ", "");
    const { payload, protectedHeader } = await jwtVerify(jwt, publicKey);
    assert.equal(payload.iss, "TEAM123456");
    assert.equal(protectedHeader.kid, "KEY1234567");
    assert.equal(widget.headers["authorization"], alert.headers["authorization"]); // token is reused
  });

  it("skips the widget push without a widget token, and does nothing without a device", async () => {
    const { pusher, sent } = make();
    await pusher.notifyDoodle({ apnsToken: "abc123", widgetToken: null, sandbox: false }, doodle);
    assert.equal(sent.length, 1);
    assert.equal(sent[0]!.sandbox, false);
    await pusher.notifyDoodle(undefined, doodle);
    assert.equal(sent.length, 1);
  });

  it("refuses tokens that aren't hex, and forgets devices Apple says are gone", async () => {
    const { pusher, sent, dead } = make(() => ({ status: 410, body: '{"reason":"Unregistered"}' }));
    await pusher.notifyDoodle({ apnsToken: "../evil", widgetToken: null, sandbox: false }, doodle);
    assert.equal(sent.length, 0);
    await pusher.notifyDoodle({ apnsToken: "abc123", widgetToken: null, sandbox: false }, doodle);
    assert.deepEqual(dead, ["abc123"]);
  });

  it("retries on the other Apple server when a token is from the other environment", async () => {
    // The widget token is sandbox-only, but the device is flagged production.
    const { pusher, sent, dead } = make((req) =>
      req.token === "def456" && !req.sandbox
        ? { status: 400, body: '{"reason":"BadDeviceToken"}' }
        : { status: 200, body: "" },
    );
    await pusher.notifyDoodle({ apnsToken: "abc123", widgetToken: "def456", sandbox: false }, doodle);
    const widgetTries = sent.filter((r) => r.token === "def456");
    assert.deepEqual(widgetTries.map((r) => r.sandbox), [false, true]); // production first, then sandbox
    assert.equal(sent.filter((r) => r.token === "abc123").length, 1); // healthy tokens aren't retried
    assert.deepEqual(dead, []);
  });

  it("gives up quietly when both servers reject the token", async () => {
    const { pusher, sent } = make(() => ({ status: 400, body: '{"reason":"BadDeviceToken"}' }));
    await pusher.notifyDoodle({ apnsToken: "abc123", widgetToken: null, sandbox: false }, doodle);
    assert.equal(sent.length, 2); // one try per server, no loop
  });

  it("never throws when Apple is unreachable", async () => {
    const pusher = apnsPusher({
      teamId: "T",
      keyId: "K",
      privateKeyPem: pem,
      bundleId: "app.doodle.ios",
      transport: async () => {
        throw new Error("network down");
      },
    });
    await pusher.notifyDoodle({ apnsToken: "abc123", widgetToken: "def456", sandbox: false }, doodle);
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

  it("validates and forgets push registrations", async () => {
    assert.equal((await call("PUT", "/device", aruzhan.token, { apnsToken: "../../x" })).status, 400);
    assert.equal((await call("PUT", "/device", aruzhan.token, { apnsToken: "abc", widgetToken: "zz!" })).status, 400);
    assert.equal((await call("PUT", "/device", aruzhan.token, { apnsToken: "abc", sandbox: true })).status, 204);
    assert.equal((await call("DELETE", "/device", aruzhan.token)).status, 204);
    assert.equal((await call("DELETE", "/device", aruzhan.token)).status, 204); // idempotent
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
