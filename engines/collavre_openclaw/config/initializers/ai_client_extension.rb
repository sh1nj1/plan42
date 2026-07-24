Rails.application.config.to_prepare do
  if defined?(Collavre::AiClient)
    # Prepend the extension if not already done
    unless Collavre::AiClient.singleton_class.method_defined?(:register_adapter)
      Collavre::AiClient.prepend(CollavreOpenclaw::AiClientExtension)
      Rails.logger.info("[CollavreOpenclaw] Extended Collavre::AiClient with adapter support")
    end

    # Register the OpenClaw adapter
    unless Collavre::AiClient.adapter_registry.key?("openclaw")
      Collavre::AiClient.register_adapter("openclaw", CollavreOpenclaw::OpenclawAdapter)
      Rails.logger.info("[CollavreOpenclaw] Registered OpenClaw adapter")
    end

    # OpenClaw uses stateful, incremental sessions and appears in the AI-agent
    # vendor dropdown. Register both into core so core needs no OpenClaw name of
    # its own to decide session support or list the vendor. Both registrations
    # are idempotent, so re-running on reload is safe.
    if Collavre::AiClient.respond_to?(:register_session_vendor)
      Collavre::AiClient.register_session_vendor("openclaw")
    end
    if Collavre::AiClient.respond_to?(:register_vendor_option)
      Collavre::AiClient.register_vendor_option("OpenClaw", "openclaw")
    end
  end
end
