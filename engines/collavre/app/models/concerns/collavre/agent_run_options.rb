# frozen_string_literal: true

module Collavre
  # An agent's defaults for how its CLI Proxy turns run: the reasoning effort
  # sent with each request, and the Codex Fast mode its workspace manifests
  # publish. See CliProxy::RunOptions for how a message overrides them.
  module AgentRunOptions
    extend ActiveSupport::Concern

    included do
      normalizes :reasoning_effort, with: ->(effort) { effort.to_s.strip.presence }
      validates :reasoning_effort, inclusion: { in: ->(agent) { agent.llm_vendor.to_s.strip.downcase == "cli_proxy" ? CliProxy::RunOptions.efforts_for(agent.llm_model) : CliProxy::RunOptions::ALL_EFFORTS } }, allow_nil: true
      after_update_commit :sync_codex_fast_mode, if: :provisioning_sync_needed?
    end

    # The Fast setting the workspace manifest publishes. Only codex_local
    # honors it, so any other model publishes false whatever was stored.
    def effective_codex_fast_mode?
      llm_vendor.to_s.strip.downcase == "cli_proxy" && codex_fast_mode? && CliProxy::RunOptions.fast_mode_supported?(llm_model)
    end

    private

    # The proxy reads Fast mode from the manifest only when it syncs, and would
    # otherwise pick a change up at its next hourly refetch.
    def provisioning_sync_needed?
      leaving = saved_change_to_llm_vendor? && llm_vendor_before_last_save.to_s.strip.downcase == "cli_proxy" && !cli_proxy_agent?
      leaving || codex_fast_mode_runtime_changed?
    end

    def codex_fast_mode_runtime_changed?
      return false unless saved_change_to_codex_fast_mode? || saved_change_to_llm_model? || saved_change_to_llm_vendor?

      was = llm_vendor_before_last_save.to_s.strip.downcase == "cli_proxy" && codex_fast_mode_before_last_save &&
        CliProxy::RunOptions.fast_mode_supported?(llm_model_before_last_save)
      was != effective_codex_fast_mode?
    end

    def sync_codex_fast_mode
      return unless agent_gateway.present?

      AgentProvisioningSyncJob.perform_later(id)
    end
  end
end
