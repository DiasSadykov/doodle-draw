const escapeHtml = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");

export type WebConfig = {
  /** Apple Team ID. Enables /.well-known/apple-app-site-association (universal links). */
  appleTeamId?: string;
  bundleId: string;
  /** Shown as the "Get the app" button once the app is published. */
  appStoreUrl?: string;
};

/** The page a shared invite link lands on. `inviter` is null when the invite is gone. */
export function invitePage(opts: { code: string; inviter: string | null; config: WebConfig }): string {
  const { code, inviter, config } = opts;
  const title = inviter ? `${escapeHtml(inviter)} invited you to Doodle` : "This invite is no longer valid";
  const body = inviter
    ? "Little drawings, right on each other's Home Screen."
    : "Ask your person to send you a new link.";

  const buttons = inviter
    ? `<a class="btn primary" href="doodle://invite/${encodeURIComponent(code)}">Open in Doodle</a>
       ${config.appStoreUrl ? `<a class="btn" href="${escapeHtml(config.appStoreUrl)}">Get the app</a>` : ""}
       <p class="code">Invite code <b>${escapeHtml(code)}</b></p>`
    : "";

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<meta property="og:title" content="${title}">
<meta property="og:description" content="${body}">
<meta name="robots" content="noindex">
<style>
  :root { color-scheme: light dark; --pink: #ff2d55; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; text-align: center;
         font: 17px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
         background: Canvas; color: CanvasText; }
  main { padding: 32px 28px; max-width: 360px; }
  .icon { width: 96px; height: 96px; border-radius: 22%; background: var(--pink); margin: 0 auto 24px; display: grid; place-items: center; }
  .icon svg { width: 52px; height: 52px; }
  h1 { font-size: 26px; margin: 0 0 8px; }
  p { margin: 0 0 24px; opacity: .65; }
  .btn { display: block; padding: 15px; border-radius: 999px; margin-top: 12px; text-decoration: none; font-weight: 600;
         color: var(--pink); background: rgba(255,45,85,.14); }
  .btn.primary { color: #fff; background: var(--pink); }
  .code { font-size: 14px; margin-top: 28px; }
</style>
</head>
<body>
<main>
  <div class="icon"><svg viewBox="0 0 100 100" fill="none" stroke="#fff" stroke-width="9" stroke-linecap="round" stroke-linejoin="round"><path d="M50 88C5 62 2 18 12 28c10 14 26 10 38 10s28 4 38-10c10-10 7 34-38 60z"/></svg></div>
  <h1>${title}</h1>
  <p>${body}</p>
  ${buttons}
</main>
</body>
</html>`;
}

export function appSiteAssociation(config: WebConfig) {
  return {
    applinks: {
      details: [{ appIDs: [`${config.appleTeamId}.${config.bundleId}`], components: [{ "/": "/i/*" }] }],
    },
  };
}
