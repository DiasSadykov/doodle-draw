export type Device = { apnsToken: string; widgetToken: string | null };

export type PushedDoodle = { id: string; senderName: string; createdAt: string };

export type Pusher = {
  /** Tell the partner's phone there is a new doodle. `device` is undefined if they never registered. */
  notifyDoodle(device: Device | undefined, doodle: PushedDoodle): Promise<void>;
};

/**
 * Placeholder until we have an Apple Developer account (APNs needs a paid key).
 * Until then the partner's app picks up new doodles with GET /doodles when it opens.
 */
export const logPusher: Pusher = {
  async notifyDoodle(device, doodle) {
    console.log(`[push] doodle ${doodle.id} from ${doodle.senderName} -> ${device ? "device registered (APNs not configured)" : "no device"}`);
  },
};
