Rails.application.config.to_prepare do
  if defined?(Collavre::AiClient)
    unless Collavre::AiClient.singleton_class.method_defined?(:register_adapter)
      Collavre::AiClient.prepend(CollavreOpenclaw::AiClientExtension)
      Rails.logger.info("[CollavreOpenclaw] Extended Collavre::AiClient with adapter support")
    end
  end
end
