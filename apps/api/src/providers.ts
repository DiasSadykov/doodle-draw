import { createRemoteJWKSet, jwtVerify } from "jose";

export type Identity = { sub: string; name: string };
export type Verifier = (token: string) => Promise<Identity>;

const googleKeys = createRemoteJWKSet(new URL("https://www.googleapis.com/oauth2/v3/certs"));

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

// Sign in with Apple slots in here later as `apple: appleVerifier(...)`.
