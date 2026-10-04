# Multiple users redesign

Doodle today pairs you with exactly one person. This redesign lets you doodle with several
people, and fixes notification taps so they open the doodle instead of a blank canvas.

This document is the front-end proposal and what it needs from the backend. The
screens are built as a SwiftUI prototype on sample data (this branch); nothing here talks to
the API yet.

- **Flows (Figma):** [Doodle · Multiple users redesign (flows)](https://www.figma.com/design/YltpKPrfNmb1jwlKzOnVLQ/Portfolio?node-id=362-2)
- **One-person home + profile (Figma, latest):** [One person · today](https://www.figma.com/design/YltpKPrfNmb1jwlKzOnVLQ/Portfolio?node-id=374-1532)
  — supersedes the 1-person and history screens on the flows page.
- **Try it:** run a Debug build → tap **Try the Multiple users redesign** (sign-in screen,
  *Pair up* screen, or the … menu on the canvas). Your avatar menu (top left) switches sample
  scenarios and can fake an incoming doodle + notification. **Leave prototype** goes back.
- **Code:** `apps/ios/Doodle/Prototype/`, compiled into Debug builds only.

## What the user sees

| Area | Behaviour |
|---|---|
| Home, 1 person | Home is that person's page and shows **today only**: their doodles from today in a swipeable carousel (newest first), and *Sent by you* below with what you sent them today. Empty states: “Nothing from Dias today” / “Nothing from Dias yet”. *Draw back* / *Draw another*. |
| Home, 2+ people | Home becomes the **Wall**: one tile per person showing their latest doodle to you (yours if they haven't sent one). Invited people show as *Invite sent*. |
| New doodles | *New* badge on tiles/cards; header says “2 new doodles” until you've swiped through them. |
| Notification tap | Opens that person's page on that doodle (fixes today's blank-canvas landing). |
| Reactions | Long-press a doodle to react (it stays in place, the rest dims, the bar opens below). One emoji per person per doodle; tap another to change, same to remove. Shown as an emoji hanging off the doodle's corner. |
| Drawing | Pen (colour sets, sizes, eraser), background colour, text, photo. All of it is rendered into the image on the phone before sending. |
| Sending | *Draw for* one person or several; one doodle goes to everyone picked. |
| Person profile | Tap their name in the header: every doodle between you (date headers, filter All / From them / From you), plus ··· → *Mute notifications* and *Remove*. |
| Your profile | Name and photo, shown to the people you doodle with. |

## Backend needs

### 1. Many connections instead of one pair
`pairs` has `UNIQUE(user_a)` / `UNIQUE(user_b)`, so a user can only ever have one partner.
Proposal: a `connections` table (two users, `status` = `invited` | `connected`, `created_at`,
`connected_at`). Invites stay as they are, but accepting one creates a connection instead of
failing with `already_paired`.

The client needs `connected_at` for the header rule “Connected 3m ago” (shown for 24h, or until
the first doodle).

### 2. Doodles to one or more people
A doodle has one sender and one or more recipients. Proposal: keep `doodles` (drop `pair_id`)
plus `doodle_recipients (doodle_id, user_id, seen_at, reaction)`.

- `POST /doodles` takes `recipients: [userId]` (one upload, fan-out on the server, one push per recipient).
- `GET /people/:id/doodles?before=…&limit=…` returns the history between me and one person,
  newest first (pages for the profile history). Home's “today” is the first page filtered on the
  phone by local date, so no extra endpoint.
- `GET /people` returns everyone I'm connected to or have invited, each with their latest doodle,
  `unseenCount`, and `connectedAt`. This powers the Wall in one request.

### 3. Seen state
`POST /doodles/:id/seen` when the user has swiped past it. This drives *New* and the
“2 new doodles” header. (There is deliberately **no** read receipt shown to the sender.)

### 4. Reactions
`PUT /doodles/:id/reaction { emoji }` / `DELETE /doodles/:id/reaction`. One per user per
doodle. A push to the sender would be nice (“Dias reacted ❤️”).

### 5. Profile
`PATCH /me { name }`, `PUT /me/photo` (image upload) → `photoUrl` on every user object the
API returns.

### 6. Push payload
Include `doodleId` **and** `senderId` so a tap can open the right page. Today it sends
`doodleId` only, and the app doesn't handle the tap yet (that part is front end).

### 7. Widget
With several people, each widget instance needs to know whose doodles it shows (widget
configuration on the phone). The server side is the widget push for every connection, not
just the one partner.

### 8. Mute and remove
- `PUT /people/:id/mute { muted }`: the server skips pushes from that person (doodles still
  arrive and the widget still updates). `muted` comes back on `GET /people`.
- `DELETE /people/:id` ends the connection for both people.

### Not needed on the server
Background colour, photo, text, brush size and colour sets are all baked into the JPEG on the
phone. The emoji animations come from Google's Noto CDN on the phone (CC BY 4.0; credit goes
in the app's About screen).

## Open questions for Dias
1. Should a widget show one chosen person, or “latest from anyone”?
2. Is there a cap on how many people you can connect to?
3. Migrate existing pairs to connections in place, or start fresh?
4. When someone is removed, what happens to the shared history and to both widgets?
5. Photo storage for profile pictures: same place as doodle images?

## Prototype notes
- New dependency: [lottie-spm](https://github.com/airbnb/lottie-spm) for the emoji animations
  (the app bundle only carries small still images). Worth keeping for the real build.
- `Info.plist` gains `NSCameraUsageDescription` (photo on canvas / profile photo).
- Not meant to merge as-is: the real build will replace the sample-data store with the API above.
