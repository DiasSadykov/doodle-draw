import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from "jose";

export type Identity = { sub: string; name: string };
/** `hint.name` is what the client knows about the person (Apple only reveals it once, to the app). */
export type Verifier = (token: string, hint?: { name?: string }) => Promise<Identity>;

const googleKeys = createRemoteJWKSet(new URL("https://www.googleapis.com/oauth2/v3/certs"));
const appleKeys = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));

/** Verifies a Google ID token issued for our iOS client id. */
export function googleVerifier(clientId: string): Verifier {
  return async (token) => {
    const { payload } = await jwtVerify(token, googleKeys, {
      issuer: ["https://accounts.google.com", "accounts.google.com"],
      audience: clientId,
    });
    if (!payload.sub) throw new Error("token has no sub");
    return { sub: payload.sub, name: typeof payload.name === "string" ? payload.name : "Friend" };
  };
}

/**
 * Verifies the identity token the iOS app gets from Sign in with Apple.
 * For a native app the audience is the app's bundle id. `sub` is stable per person per app.
 *
 * Apple includes the person's name only on their very first authorization and only to the
 * app, never in the token, so the app passes it along as `hint.name`. We only use it when
 * creating the account; later sign-ins ignore it.
 */
export function appleVerifier(bundleId: string, keys: JWTVerifyGetKey = appleKeys): Verifier {
  return async (token, hint) => {
    const { payload } = await jwtVerify(token, keys, { issuer: "https://appleid.apple.com", audience: bundleId });
    if (!payload.sub) throw new Error("token has no sub");
    const name = hint?.name?.trim().slice(0, 60);
    return { sub: payload.sub, name: name || "Friend" };
  };
}

/**
 * Development only: the "token" is just a name, e.g. "dias". Lets you test pairing
 * with two fake users before Google sign-in is set up.
 *
 * On a public server, pass a passphrase (DEV_AUTH_KEY): the token must then be
 * "<passphrase>:<name>", otherwise anyone could log in as any name.
 */
export function devVerifier(passphrase?: string): Verifier {
  return async (token) => {
    let name = token;
    if (passphrase) {
      const prefix = `${passphrase}:`;
      if (!token.startsWith(prefix)) throw new Error("bad passphrase");
      name = token.slice(prefix.length);
    }
    name = name.trim();
    if (!name) throw new Error("empty name");
    return { sub: name.toLowerCase(), name };
  };
}
