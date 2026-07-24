# frozen_string_literal: true

# GitHub-synced Markdown creatives are read-only in Collavre: their description
# is owned by the upstream repository and must not be edited in-app. Register
# the source type into the core read-only-source registry so core enforces the
# read-only behavior (validation, attachment embedding, tree write flags)
# without naming GitHub. Runs on boot and every reload so the registration
# survives Zeitwerk clearing Collavre::Creative's class state.
Rails.application.config.to_prepare do
  if defined?(Collavre::Creative)
    Collavre::Creative.register_read_only_source("github_markdown")
  end
end
