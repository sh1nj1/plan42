# frozen_string_literal: true

# An OpenClaw gateway error banner marks a task result the agent never actually
# produced, so the trigger loop must retry it without consuming an iteration.
# Register the OpenClaw-specific signature into the core trigger-loop infra-error
# registry so core keeps only vendor-neutral patterns. Runs on boot and every
# reload; registration is idempotent.
Rails.application.config.to_prepare do
  if defined?(Collavre::TriggerLoopCheckJob)
    Collavre::TriggerLoopCheckJob.register_infrastructure_error_pattern(/OpenClaw Error/i)
  end
end
