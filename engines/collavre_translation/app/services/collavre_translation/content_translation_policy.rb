module CollavreTranslation
  class ContentTranslationPolicy
    def self.enabled?(record, reader)
      creative = record.is_a?(Collavre::Comment) ? record.creative : record.effective_origin
      public_content = creative.has_permission?(nil, :read)
      public_content &&= !record.private? if record.is_a?(Collavre::Comment)
      return CollavreTranslation.enabled_for?(record.user) if public_content

      CreativeTranslationPolicy.enabled?(reader)
    end
  end
end
