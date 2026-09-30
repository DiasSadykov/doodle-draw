import { connect, type ClientHttp2Session } from "node:http2";
import { importPKCS8, SignJWT } from "jose";

export type Device = {
  apnsToken: string;
  widgetToken: string | null;
  /** True for builds installed from Xcode (Apple uses a separate push server for them). */
  sandbox: boolean;
};

export type PushedDoodle = { id: string; senderName: string; createdAt: string };

export type Pusher = {
  /** Tell the partner's phone there is a new doodle. `device` is undefined if they never registered. */
  notifyDoodle(device: Device | undefined, doodle: PushedDoodle): Promise<void>;
};

/** Used when APNs isn't configured: the partner's app picks doodles up when it opens. */
export const logPusher: Pusher = {
  async notifyDoodle(device, doodle) {
    console.log(`[push] doodle ${doodle.id} from ${doodle.senderName} -> ${device ? "device registered (APNs not configured)" : "no device"}`);
  },
};

// ---- APNs ---------------------------------------------------------------

export type ApnsRequest = { sandbox: boolean; token: string; headers: Record<string, string>; body: string };
export type ApnsResponse = { status: number; body: string };
export type ApnsTransport = (req: ApnsRequest) => Promise<ApnsResponse>;

const HOSTS = { production: "https://api.push.apple.com", sandbox: "https://api.sandbox.push.apple.com" };

/** One long-lived HTTP/2 connection per Apple host; APNs wants connections kept open. */
export function http2Transport(): ApnsTransport {
  const sessions = new Map<string, ClientHttp2Session>();
  const sessionFor = (origin: string) => {
    let session = sessions.get(origin);
    if (!session || session.closed || session.destroyed) {
      session = connect(origin);
      session.on("error", () => sessions.delete(origin));
      session.on("close", () => sessions.delete(origin));
      session.unref(); // never keep the process alive just for push
      sessions.set(origin, session);
    }
    return session;
  };

  return (req) =>
    new Promise((resolve, reject) => {
      const origin = req.sandbox ? HOSTS.sandbox : HOSTS.production;
      const stream = sessionFor(origin).request({
        ":method": "POST",
        ":path": `/3/device/${req.token}`,
        ...req.headers,
      });
      let status = 0;
      let body = "";
      stream.setEncoding("utf8");
      stream.on("response", (headers) => (status = Number(headers[":status"])));
      stream.on("data", (chunk: string) => (body += chunk));
      stream.on("end", () => resolve({ status, body }));
      stream.on("error", reject);
      stream.setTimeout(10_000, () => {
        stream.close();
        reject(new Error("APNs request timed out"));
      });
      stream.end(req.body);
    });
}

export type ApnsOptions = {
  teamId: string;
  keyId: string;
  /** Contents of the AuthKey_XXXX.p8 file. */
  privateKeyPem: string;
  bundleId: string;
  transport?: ApnsTransport;
  /** Called when Apple says a token is dead, so it can be forgotten. */
  onUnregistered?: (token: string) => void;
};

// Apple wants a fresh provider token every 20-60 minutes.
const PROVIDER_TOKEN_TTL_MS = 40 * 60 * 1000;
const isHex = (s: string) => /^[0-9a-fA-F]+$/.test(s);

export function apnsPusher(opts: ApnsOptions): Pusher {
  const transport = opts.transport ?? http2Transport();
  // Cache the promise, not the string, so pushes started together share one signing.
  let cached: { jwt: Promise<string>; at: number } | undefined;

  function providerToken(): Promise<string> {
    if (cached && Date.now() - cached.at < PROVIDER_TOKEN_TTL_MS) return cached.jwt;
    const jwt = importPKCS8(opts.privateKeyPem, "ES256").then((key) =>
      new SignJWT({}).setProtectedHeader({ alg: "ES256", kid: opts.keyId }).setIssuer(opts.teamId).setIssuedAt().sign(key),
    );
    const entry = { jwt, at: Date.now() };
    cached = entry;
    jwt.catch(() => {
      if (cached === entry) cached = undefined; // don't cache a failure
    });
    return jwt;
  }

  async function send(
    kind: string,
    token: string,
    sandbox: boolean,
    headers: Record<string, string>,
    payload: unknown,
  ) {
    if (!isHex(token)) return; // never let a stored value shape the request path
    const allHeaders = { authorization: `bearer ${await providerToken()}`, "content-type": "application/json", ...headers };
    const body = JSON.stringify(payload);
    const reasonOf = (res: ApnsResponse) => {
      try {
        return (JSON.parse(res.body) as { reason?: string }).reason ?? "";
      } catch {
        return "";
      }
    };

    let res = await transport({ sandbox, token, headers: allHeaders, body });
    if (res.status === 200) return;

    // A token minted by a different kind of build (Xcode = sandbox, TestFlight/App Store = production)
    // is rejected as BadDeviceToken. This happens when a widget keeps its old token after the app is
    // reinstalled from another source, so try the other Apple server before giving up.
    if (res.status === 400 && reasonOf(res) === "BadDeviceToken") {
      const retry = await transport({ sandbox: !sandbox, token, headers: allHeaders, body });
      if (retry.status === 200) {
        console.log(`[push] ${kind} token only works on ${sandbox ? "production" : "sandbox"}; delivered there`);
        return;
      }
    }

    const reason = reasonOf(res);
    console.error(`[push] ${kind} rejected: ${res.status} ${reason}`);
    if (res.status === 403) cached = undefined; // expired/invalid provider token: sign a new one next time
    if (res.status === 410) opts.onUnregistered?.(token);
  }

  return {
    async notifyDoodle(device, doodle) {
      if (!device) return;
      const jobs = [
        // The visible notification.
        send(
          "alert",
          device.apnsToken,
          device.sandbox,
          { "apns-topic": opts.bundleId, "apns-push-type": "alert", "apns-priority": "10" },
          {
            aps: { alert: { title: doodle.senderName, body: "sent you a doodle" }, sound: "default", "thread-id": "doodle" },
            doodleId: doodle.id,
          },
        ),
      ];
      if (device.widgetToken) {
        // Tells WidgetKit to refresh the Home Screen widget right now.
        jobs.push(
          send(
            "widget",
            device.widgetToken,
            device.sandbox,
            { "apns-topic": `${opts.bundleId}.push-type.widgets`, "apns-push-type": "widgets", "apns-priority": "10" },
            { aps: { "content-changed": true } },
          ),
        );
      }
      // One failing push must not stop the other.
      await Promise.all(jobs.map((job) => job.catch((e) => console.error("[push] failed", e))));
    },
  };
}
