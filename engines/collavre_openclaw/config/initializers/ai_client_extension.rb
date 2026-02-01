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
  end
end
