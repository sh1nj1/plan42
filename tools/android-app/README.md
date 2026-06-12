# Collavre Voice (Android)

A voice-only Android companion for Collavre. Its one job — the part no OS
assistant can take, because it needs Collavre's internal agent state — is the
**hands-free agent message loop**:

```
agent replies in a topic → notification lands in the user's Inbox#System
  → app receives it as an event → TTS reads the full message aloud
  → speech auto-resumes → user speaks a reply
  → reply is relayed to that message's ORIGIN topic
```

Music / YouTube / article-reading are intentionally **out of scope** (the OS
assistant does them better). This app is the wedge: hear agent messages read
aloud, answer by voice, and have answers land on the right thread.

## The message queue

Inbox#System is the source of truth. Every agent reply the user should hear
arrives there (mention, or write-access user who hasn't seen it) and surfaces in
the app as an event. The app:

- **lists** each event by its origin **`Creative#Topic`** title (not the
  System topic itself), newest first;
- **reads** events one at a time through a **sequential queue** — a new event
  arriving while one is being read/answered waits its turn rather than
  interrupting;
- after reading, **auto-listens**; if the user speaks, the reply is relayed to
  that event's **origin topic**; if the user stays silent, nothing is sent and
  the next queued event is read.

Tapping a row reads that thread's latest message and listens. A plain mic press
with nothing selected routes the utterance to **Inbox#Main** (a new piece of
work), exactly like typing in the inbox chat. Identifiers are event ids and
topic ids — never spoken — so there are no ordinals to track.

## Build

Requirements: JDK 17, Android SDK with platform 35 (`compileSdk 35`, `minSdk 26`).

```bash
cd tools/android-app
echo "sdk.dir=$HOME/Library/Android/sdk" > local.properties   # or set ANDROID_HOME
./gradlew :app:assembleDebug
# → app/build/outputs/apk/debug/app-debug.apk
./gradlew installDebug   # to a connected device/emulator
```

The Gradle wrapper pins Gradle 8.9 (AGP 8.6.1, Kotlin 2.0.21, Compose, Hilt).

## First run

1. Grant **microphone** and (Android 13+) **notifications** when prompted.
2. Open **Settings** (gear, top-right):
   - **Collavre server URL** — defaults to `https://collavre.com`; change for a
     self-hosted instance or a local preview (see below).
   - **API token** — a Doorkeeper access token for your Collavre user.
   - TTS speed, language (`ko-KR` / `en-US`), and "speak agent events" toggle.
3. Tap the big mic button and speak:
   - With a message selected (or just-read), your words reply to that thread.
   - With nothing selected, your words start new work in Inbox#Main
     (e.g. "OpenClaw PR 검토해").
   - For a permission prompt, answer with allow/deny ("승인" / "거절").

A foreground service keeps polling `agent_events` while backgrounded and posts a
notification (with ✓/✗ quick actions) for each new event; tapping it opens the
app and starts listening for your answer. **Push (FCM) is wired but dormant** —
see [Push notifications](#push-notifications-fcm); without credentials the app
runs on polling alone.

## Connecting to a local Rails preview (tailscale)

The companion talks to `/api/v1/mobile/*`, implemented in the `collavre` engine.
To E2E test against a local preview without https:

1. Boot the preview server bound to all interfaces (NOT `bin/dev` — port clash):
   ```bash
   cd <plan42 worktree>
   PORT=4222 bin/rails server -b 0.0.0.0
   ```
   Reach it at `http://macbook-pro.tailadceed.ts.net:4222`.
2. Mint a Doorkeeper token for your user:
   ```bash
   bin/rails runner 'u=Collavre::User.find_by(email:"you@example.com"); \
     app=Doorkeeper::Application.create!(name:"voice",redirect_uri:"urn:ietf:wg:oauth:2.0:oob",scopes:"public",owner:u); \
     puts Doorkeeper::AccessToken.create!(application:app,resource_owner_id:u.id,scopes:"public").token'
   ```
3. In the app's Settings, set the server URL to the tailscale URL and paste the
   token. The debug build allows cleartext only for the tailscale/localhost
   hosts (see `res/xml/network_security_config.xml`); production stays https.

## Push notifications (FCM)

Event delivery is **polling by default, push when configured**. The push client
is fully scaffolded but credential-gated: the build skips the Google Services
plugin and `FirebaseApp` never initializes unless a `google-services.json` is
present, so the app builds and runs on polling with no Firebase setup.

To light it up (collavre.com only — the sender ID is baked into the build, so
self-hosted servers stay on polling):

1. Create a Firebase project, add an Android app with package
   `com.collavre.voice`, and drop the generated `google-services.json` into
   `tools/android-app/app/`. The next build auto-applies the plugin and push
   activates — no code change.
2. On the server, set the FCM v1 service-account credentials
   (`config.x.fcm_service`) so `Collavre::PushNotificationJob` can send.
3. Remaining server wiring (one follow-up): enqueue `PushNotificationJob` to the
   topic owner's devices when a permission-request comment is created (the
   `approval_requested` source in `AgentEventsController#index`). The device
   registration endpoint and the app receiver already exist; this is the only
   missing hop. Send pushes as **data messages** with keys `event_id, type,
   title, summary, speak, requires_response, topic_id, created_at` — `CollavreMessagingService`
   maps them to the same notification + spoken summary the poll loop produces.

Polling stays as the self-hosted fallback; do not remove it.

## Architecture

| Component | Role |
|---|---|
| `MainActivity` / `MainScreen` / `SettingsScreen` | Compose UI: one mic button, status chip, live caption, `Creative#Topic` message list, settings |
| `VoiceCommandService` | Single orchestration entry point: the sequential message queue (read → auto-listen → relay to origin topic) + cold mic to Inbox#Main. Future BT media-button driver hooks here |
| `TtsManager` / `SpeechRecognizerManager` | TextToSpeech / SpeechRecognizer wrappers |
| `AgentEventRepository` | `/api/v1/mobile/*` calls + `since` polling cursor |
| `AgentEventService` | Foreground (`dataSync`) poll loop → notifications + spoken summaries; registers FCM token on start |
| `CollavreMessagingService` | FCM receiver (push path): `onNewToken` → device registration, `onMessageReceived` → notification + spoken summary. Dormant without `google-services.json` |
| `PushRegistrar` | Guards Firebase availability so the app no-ops cleanly when push is unconfigured |
| `QuickResponseReceiver` | Notification ✓/✗ → `agent_events/:id/respond` |
| `CollavreApi` / `ConfigInterceptor` | Retrofit; rewrites host/scheme/port + Bearer per request from settings |
| `SettingsRepository` | DataStore (url, token, ttsRate, locale, device id, since cursor) |
| `PermissionManager` | RECORD_AUDIO + POST_NOTIFICATIONS (13+) |

## Server contract

Implemented in `engines/collavre/.../api/v1/mobile/`:

- `GET  /api/v1/mobile/agent_events?since=&device_id=` → events sourced from the
  user's Inbox#System stream. Each carries the origin `Creative#Topic` title, the
  full message as `summary` (markdown links flattened for TTS), `topic_id`, and
  `requires_response`. `since` is a microsecond-precision (`iso8601(6)`) cursor.
- `POST /api/v1/mobile/agent_events/:id/respond` → `{response}` branches by event
  kind: permission comment ⇒ allow/deny (button-by-voice); ordinary agent message
  ⇒ free text relayed to the event's origin topic as a `question` reply (so it
  posts a new comment and re-notifies, rather than updating in place).
- `POST /api/v1/mobile/voice_commands` → `{text}` → posts to Inbox#Main; dispatch
  then matches an agent via `routing_expression`.
- `POST /api/v1/mobile/devices` → FCM token registration (app client wired; see
  [Push notifications](#push-notifications-fcm)).

Response routing is server-side and explicit: a reply targets the event's origin
topic by id — there is no spoken-ordinal grammar or intent classifier (that
subsystem was removed; selection is by tap, identifiers are ids).
