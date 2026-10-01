# Collavre Translation

Optional comment and creative translation engine. Core content and agent context always retain
original text. Only authenticated, authorized readers trigger translation, when a
comment enters the viewport. Responses are fetched per viewer, never broadcast
on the shared comment stream.

Configure the shared model in **Admin → Integrations → Comment translation**
(`translation_llm_vendor`, `translation_llm_model`). The corresponding deployment
variables are `TRANSLATION_LLM_VENDOR` and `TRANSLATION_LLM_MODEL`. Alternatively,
enable with a host initializer:

```ruby
CollavreTranslation.vendor = "google" # google, gemini, openai, anthropic
CollavreTranslation.model = "YOUR_CONFIGURED_MODEL"
```

Uses the existing provider API keys from Collavre integration settings. A blank
model disables translation (the default). Removing the engine and its host JS
registration disables the feature without changing core models or columns.

Targets English and Korean from the reader's `User#locale`. CLD3 detects source
language locally on first read. Hangul-only prose is recognized even in short
comments; other short or unreliable text stays in its original language. Code, URLs, mentions, HTML tags and Markdown links are masked and
restored locally. Missing or duplicate placeholders fail closed.

Translations are shared by source record, target locale and SHA-256 of the source.
Concurrent requests claim one job atomically. Source edits select a new cache
entry; jobs discard results if the source changes during translation. Deleting
a comment deletes its cached translations. Failed translations retain the
original; no automatic paid retry. An interrupted worker leaves a processing
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
user preference gate when available, falling back to `enabled?` until the separate
user preference feature is installed. User preference storage and settings UI,
per-user quotas and dedicated usage reporting remain separate follow-ups.

The host runs the `translations` queue with a dedicated two-thread, one-process
worker in every environment. Slow provider calls do not occupy default or AI
agent worker threads. Other hosts must configure a worker for this queue.
