module CollavreTranslation
  class ContentTranslationPolicy
    def self.enabled?(record, reader)
      return CollavreTranslation.enabled_for?(record.user) if public_content?(record)

      CreativeTranslationPolicy.enabled?(reader)
    end

    # Public content follows its author's preference, so the answer is the same
    # for every reader and shared markup can decide it without a request.
    def self.public_content?(record)
      creative = record.is_a?(Collavre::Comment) ? record.creative : record.effective_origin
      public_content = creative.has_permission?(nil, :read)
      public_content &&= !record.private? if record.is_a?(Collavre::Comment)
      public_content
    end
  end
end
