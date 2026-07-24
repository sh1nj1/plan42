require "test_helper"

module Collavre
  class ChannelBotSeedTest < ActiveSupport::TestCase
    test "channel bot user exists and is not an ai_user" do
      bot = User.find_by(email: "channel@collavre.local")
      assert bot, "Channel bot user must exist"
      refute_predicate bot, :ai_user?
      assert_equal "Channel", bot.name
    end
  end
end
