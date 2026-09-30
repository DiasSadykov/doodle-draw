import { jwtVerify, SignJWT } from "jose";

const key = (secret: string) => new TextEncoder().encode(secret);

/** Our own session token, issued after a provider token has been verified. */
export function signSession(userId: string, secret: string): Promise<string> {
  return new SignJWT({})
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime("180d")
    .sign(key(secret));
}

/** Returns the user id, or null if the token is missing, forged, or expired. */
export async function verifySession(token: string, secret: string): Promise<string | null> {
  try {
    const { payload } = await jwtVerify(token, key(secret), { algorithms: ["HS256"] });
    return payload.sub ?? null;
  } catch {
    return null;
  }
}
