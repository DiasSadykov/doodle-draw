# Doodle API

Hono + SQLite (Node's built-in `node:sqlite`). Needs Node 22.13+.

```bash
npm install
npm run dev     # http://localhost:8787, with DEV_AUTH=1
npm test
```

Data lives in `./data` (`doodle.db` plus `images/<id>.jpg`). Set `DATA_DIR` to move it.

## Conventions

- JSON everywhere except the doodle upload (multipart).
- After signing in, send `Authorization: Bearer <token>` on every request.
- Errors are `{ "error": "code" }` with a matching HTTP status.

## Endpoints

| | | Body → Response |
|---|---|---|
| `POST` | `/auth` | `{ provider, token }` → `{ token, user }` |
| `GET` | `/me` | → `{ user, partner \| null }` |
| `POST` | `/invites` | → `201 { code, expiresAt }` |
| `POST` | `/pair` | `{ code }` → `{ partner }` |
| `DELETE` | `/pair` | → `204` (also deletes the shared doodles) |
| `PUT` | `/device` | `{ apnsToken, widgetToken? }` → `204` |
| `POST` | `/doodles` | multipart `image` (JPEG, ≤ 2 MB) + `hasPhoto` → `201 Doodle` |
| `GET` | `/doodles?before=&limit=` | → `[Doodle]`, newest first (`limit` ≤ 50, default 20) |
| `GET` | `/doodles/:id/image` | → `image/jpeg` |

`Doodle` is `{ id, from: "you" | "partner", hasPhoto, createdAt }` — see `packages/contracts/doodle.schema.json`.

Error codes: `unauthorized` · `unsupported_provider` · `invalid_token` · `bad_request` · `invite_not_found` · `invite_expired` · `own_invite` · `already_paired` · `not_paired` · `image_required` · `not_jpeg` · `too_large` · `not_found`

## Sign-in

`provider` picks the verifier:

- `google` — `token` is a Google ID token; enabled when `GOOGLE_CLIENT_ID` is set.
- `dev` — `token` is just a name (`"dias"`); enabled with `DEV_AUTH=1`. Handy for testing pairing with two fake users. On a public server set `DEV_AUTH_KEY` instead: the token is then `"<key>:<name>"`, so strangers can't log in as you.
- `apple` — later, as one more entry in `src/providers.ts`.

## Try it

```bash
B=http://localhost:8787
TA=$(curl -s $B/auth -H 'content-type: application/json' -d '{"provider":"dev","token":"Dias"}' | jq -r .token)
TB=$(curl -s $B/auth -H 'content-type: application/json' -d '{"provider":"dev","token":"Aruzhan"}' | jq -r .token)
CODE=$(curl -s -X POST $B/invites -H "authorization: Bearer $TA" | jq -r .code)
curl -s -X POST $B/pair -H "authorization: Bearer $TB" -H 'content-type: application/json' -d "{\"code\":\"$CODE\"}"
curl -s -X POST $B/doodles -H "authorization: Bearer $TA" -F image=@doodle.jpg -F hasPhoto=false
curl -s $B/doodles -H "authorization: Bearer $TB"
```

## Deploy (any VPS with Docker)

```bash
cp .env.example .env     # set DOMAIN, SESSION_SECRET, GOOGLE_CLIENT_ID
docker compose up -d     # Caddy handles HTTPS; data persists in the `data` volume
```

## Not built yet

- **Push (APNs):** `src/push.ts` only logs. Needs the paid Apple Developer account. Until then the app fetches `GET /doodles` when it opens.
- **Backups:** add [Litestream](https://litestream.io) for `doodle.db` and copy `images/` off the box before relying on it.
