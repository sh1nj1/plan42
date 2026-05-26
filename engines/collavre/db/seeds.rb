module Collavre
  module ChannelBotSeed
    EMAIL = "channel@collavre.local"
    NAME = "Channel"

    def self.call
      user = User.find_or_initialize_by(email: EMAIL)
      user.name = NAME
      user.password = SecureRandom.hex(32) if user.new_record?
      user.email_verified_at ||= Time.current
      user.searchable = false if user.respond_to?(:searchable=)
      user.llm_vendor = nil
      user.save!
      Rails.logger.info "[Collavre] Channel bot user ensured: #{EMAIL}"
      user
    end
  end
end

Collavre::ChannelBotSeed.call
