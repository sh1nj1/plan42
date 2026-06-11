# Collavre Voice (Android)

A voice-only Android companion for Collavre. Its one job — the part no OS
assistant can take, because it needs Collavre's internal agent state — is the
**hands-free agent decision loop**:

```
agent needs approval
  → app polls agent_events → TTS: "작업 1, OpenClaw PR 검토. 파일 3개 수정 승인할까요?"
  → speech auto-resumes → "1번 승인"
  → server resolves ref 1 → decide_claude_channel_permission! → "승인했습니다."
```

Music / YouTube / article-reading are intentionally **out of scope** (the OS
assistant does them better). This app is the wedge: speak a command, control
Collavre agents, and hear agent events as decision-ready summaries.

## Why a stable spoken number ("1번")

Collavre's internal identifiers are UUIDs/DB ids — unspeakable. The server's
`mobile_voice_refs` table assigns each pending approval / running session a
short ordinal that is **pinned across polling cycles**, so "1번 승인" always
means the same task between two utterances. The app just speaks the number the
server gives it and sends the number back.

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
3. Tap the big mic button and speak. Examples:
   - "OpenClaw PR 검토해" (start work) · "상태 알려줘" (status)
   - "1번 승인" / "2번 거절" · "1번 멈춰" / "2번 계속"

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
   missing hop. Send pushes as **data messages** with keys `event_id, ref, type,
   title, summary, requires_response, topic_id, created_at` — `CollavreMessagingService`
   maps them to the same notification + spoken summary the poll loop produces.

Polling stays as the self-hosted fallback; do not remove it.

## Architecture

| Component | Role |
|---|---|
| `MainActivity` / `MainScreen` / `SettingsScreen` | Compose UI: one mic button, status chip, active-task list, recent exchanges, settings |
| `VoiceCommandService` | Single orchestration entry point: push-to-talk + event answers (speak → auto-listen → relay). Future BT media-button driver hooks here |
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

- `GET  /api/v1/mobile/agent_events?since=&device_id=` → events with stable `ref`
  + decision summary.
- `POST /api/v1/mobile/agent_events/:id/respond` → `{response}` branches by event
  kind: permission comment ⇒ allow/deny (button-by-voice); ordinary agent message
  ⇒ free text relayed verbatim.
- `POST /api/v1/mobile/voice_commands` → `{text}` (also accepts a pre-structured
  `{intent}` for a future on-device LLM seam).
- `GET  /api/v1/mobile/sessions` → active task list.
- `POST /api/v1/mobile/devices` → FCM token registration (app client wired; see
  [Push notifications](#push-notifications-fcm)).

Intent interpretation is server-side and **hybrid**: a deterministic grammar
fast-path for the bounded, safety-critical commands ("N번 승인/거절/멈춰/계속"),
falling back to a seeded `voice-intent-resolver` AI agent (swap vendor/model in
the existing edit_ai UI — no model id is hardcoded) for natural variants and
aliases ("방금/마지막/전부").
