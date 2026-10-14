# Decision adapter

`Collavre::AiClient#judge(input, questions:)` evaluates application data with
named choice, probability, or score questions. Callers receive string-keyed
`answers`, `reason`, and `source` (`judge` or `chat`). Invalid or missing answers
raise instead of becoming a successful verdict.

```ruby
client.judge("Task instructions and evidence", questions: {
  status: {
    type: :choice,
    instructions: "Were all actions executed?",
    options: { DONE: "All actions executed", CONTINUE: "Work remains" }
  }
})
# {"answers" => {"status" => {"choice" => "DONE"}},
#  "reason" => "", "source" => "judge"}
```

## Vendors and credentials

- OpenAI supports chat and the native `/decisions` operation. It uses the
  existing OpenAI agent key, model, and optional gateway URL. A compatible
  gateway returning HTTP 404, 405, or 501 falls back to chat. Authentication,
  rate-limit, and server failures propagate.
- TypesafeAI (`typesafe`) supports native judgments only. Configure the agent's
  API key, judgment model (for example `jev-latest`), and optionally its gateway
  URL. These map to RubyLLM's `typesafe_api_key` and `typesafe_api_base`.
- Other vendors default to chat capability. RubyLLM-backed vendors use a JSON
  schema. Explicit schema rejection retries with a JSON-only prompt; adapter
  vendors keep their existing public `chat` implementation and use that prompt.

Extensions declare capabilities with
`AiClient.register_vendor_capabilities(vendor, capabilities: %i[chat judge])`.
`AiClient.supports?(vendor, capability)` and `User#supports?` expose the registry.
Native-only agents are excluded from mentions and chat execution.

Chat probability values are uncalibrated model estimates. The adapter does not
silently convert a probability question to a categorical question or imply
that native and chat probabilities have identical statistical properties.

## Trigger loops

Both status fallback and completion verification use this interface. Selection
starts at the task creative, including its inherited shares, and requires
feedback permission or higher. The closest effective share governs each
agent's permission; a nearer read/no-access share excludes that agent. Native
judgment agents are preferred; completion verification prefers another native
agent before self-verification. Chat fallback also prefers another verifier.

Chat judgments return the status and explanation in one request. Native
judgments have no free-form reason; an INCOMPLETE verdict optionally asks an
authorized shared chat agent for the missing actions. Without one, a localized
default explanation is used. Empty, malformed, or failed verification does not
complete the loop. Existing behavior accepting an explicit DONE claim when no
verifier is shared remains available.

Both paths use the existing interaction logging and LLM usage attribution.
Prompt injection detection is outside this change.
