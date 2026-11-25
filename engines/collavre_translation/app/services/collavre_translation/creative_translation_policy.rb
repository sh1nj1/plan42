module CollavreTranslation
  class CreativeTranslationPolicy
    def self.enabled?(user)
      return false unless user
      return CollavreTranslation.enabled_for?(user) if CollavreTranslation.respond_to?(:enabled_for?)

      CollavreTranslation.enabled?
    end
  end
end
