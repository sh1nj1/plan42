module Collavre
  module ChannelBotSeed
    def self.call
      email = Channel::BOT_EMAIL
      name  = Channel::BOT_NAME
      user = User.find_or_initialize_by(email: email)
      user.name = name
      user.password = SecureRandom.hex(32) if user.new_record?
      user.email_verified_at ||= Time.current
      user.searchable = false if user.respond_to?(:searchable=)
      user.llm_vendor = nil
      user.save!
      Rails.logger.info "[Collavre] Channel bot user ensured: #{email}"
      user
    end
  end
end

Collavre::ChannelBotSeed.call
