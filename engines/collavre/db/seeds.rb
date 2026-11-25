Collavre::Channel.ensure_bot_user!
Rails.logger.info "[Collavre] Channel bot user ensured: #{Collavre::Channel::BOT_EMAIL}"
Collavre::LlmModel.seed_default_suggestions!
Collavre::Kollavy.seed!
