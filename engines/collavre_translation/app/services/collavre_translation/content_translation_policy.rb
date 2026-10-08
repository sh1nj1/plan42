module CollavreTranslation
  class ContentTranslationPolicy
    def self.enabled?(record, reader)
      creative = record.is_a?(Collavre::Comment) ? record.creative : record.effective_origin
      public_content = creative.has_permission?(nil, :read)
      public_content &&= !record.private? if record.is_a?(Collavre::Comment)
      return CollavreTranslation.enabled_for?(record.user) if public_content

      CreativeTranslationPolicy.enabled?(reader)
    end

    def self.reader_enabled?(reader, creative)
      CreativeTranslationPolicy.enabled?(reader) ||
        (creative && creative.has_permission?(reader, :read) &&
          creative.has_permission?(nil, :read) && CollavreTranslation.enabled?)
    end
  end
end
