# Collavre Translation

Optional comment translation engine. Core content and agent context always retain
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
language locally on first read; short or unreliable text stays in its original
language. Code, URLs, mentions, HTML tags and Markdown links are masked and
restored locally. Missing or duplicate placeholders fail closed.

Translations are shared by comment, target locale and SHA-256 of the source.
Concurrent requests claim one job atomically. Source edits select a new cache
entry; jobs discard results if the source changes during translation. Deleting
a comment deletes its cached translations. Failed translations retain the
original; no automatic paid retry. An interrupted worker leaves a processing
row; operators can reset it to pending to retry. Old source revisions are
retained until the comment is deleted.

Phase one covers comments. Creative HTML translation, user preferences,
per-user quotas and dedicated usage reporting are separate follow-ups.

The host runs the `translations` queue with a dedicated two-thread, one-process
worker in every environment. Slow provider calls do not occupy default or AI
agent worker threads. Other hosts must configure a worker for this queue.
