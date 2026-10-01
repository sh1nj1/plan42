# Collavre Translation

Optional comment and creative translation engine. Core content and agent context always retain
original text. Only authenticated, authorized readers trigger translation, when a
comment enters the viewport. Responses are fetched per viewer, never broadcast
on the shared comment stream.

Translation uses `COLLAVRE_DEFAULT_LLM_VENDOR` and `COLLAVRE_DEFAULT_LLM_MODEL`
by default (Gemini / `gemini-3.1-flash-lite` when unset). Override the model in **Admin → Integrations → Comment translation**
(`translation_llm_vendor`, `translation_llm_model`). The corresponding deployment
variables are `TRANSLATION_LLM_VENDOR` and `TRANSLATION_LLM_MODEL`. Alternatively,
override with a host initializer:

```ruby
CollavreTranslation.vendor = "google" # google, gemini, openai, anthropic
CollavreTranslation.model = "YOUR_CONFIGURED_MODEL"
```

Uses the existing provider API keys from Collavre integration settings. Blank integration settings fall back to the application defaults. Setting
`CollavreTranslation.model = ""` in a host initializer disables translation. Removing the engine and its host JS
registration disables the feature. This engine owns its tables and the user
preference column; core registers no translation-specific settings.

Targets English and Korean from the reader's `User#locale`. CLD3 detects source
language locally on first read. Hangul-only prose is recognized even in short
comments; other short or unreliable text stays in its original language. Code, URLs, mentions, HTML tags and Markdown links are masked and
restored locally. Missing or duplicate placeholders fail closed.

Translations are shared by source record, target locale and SHA-256 of the source.
Concurrent requests claim one job atomically. Source edits select a new cache
entry; jobs discard results if the source changes during translation. Deleting
a comment deletes its cached translations. Failed translations retain the
original. Failed comments show a Translate button for an explicit retry. Failed
creatives retry when their row is loaded again; polling does not repeatedly retry
provider failures. An interrupted worker leaves a processing
row; operators can reset it to pending to retry. Old source revisions are
retained until the comment is deleted.

Creative titles and bodies use the same cache, job claims and translation queue.
Only prose text nodes are translated; HTML attributes, links, media, code blocks
and mention subtrees stay local. The viewer changes text nodes in place and can
toggle back to the original. Editing, exports and agent context retain the source.
Short creative titles are sent to the translator even when local detection is
uncertain. Linked creatives share their origin cache; both link and origin read
permissions are checked. Requests and polling stop when rows disappear or their
source changes. Provider failures preserve the original display.

The creative UI and API call the shared `CollavreTranslation.enabled_for?(user)`
user preference gate for the reader.
The creative controller mounts once on the reader index page, never in shared
row broadcasts. Its observer translates live appended/replaced rows using the
reader session; background renderer and sender preferences cannot suppress it.
After source permission checks, API requests return 403 for a disabled reader
and 503 for a disabled engine, before cache reads or job requests.
User preferences are owned and migrated by this engine on the shared user table as `Collavre::User#auto_translation_enabled?`
(default true, including existing users), saved through the authorized profile
update through the generic `Collavre::ProfilePreferences` parameter registry
and `profile_preferences` view slot. Its preference controller clears Turbo
snapshots when that form submits, so Back re-renders the saved reader gate.
`CollavreTranslation.enabled_for?(user)` is the shared availability gate
for comments and creative translation. Use it before mounting frontend
controllers, and check the preference after source authorization in endpoints.
Shared live comment broadcasts contain inert templates, independent of the author
or background renderer. The request-rendered `comment-translation-reader`
controller is mounted only when `enabled_for?(Current.user)` passes and hydrates
initial, appended, and replaced comment templates. OFF readers never mount a
translation controller, make requests, or poll. Reuse a per-reader gate for
creative broadcasts as well; do not gate shared HTML using `Current.user`.
Disabled readers cannot fetch cached results or enqueue jobs. Original content
and AI context remain unchanged.

Per-user quotas and dedicated usage reporting are separate follow-ups.

The host runs the `translations` queue with a dedicated two-thread, one-process
worker in every environment. Slow provider calls do not occupy default or AI
agent worker threads. Other hosts must configure a worker for this queue.
