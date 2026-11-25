require "test_helper"

module Collavre
  class ChannelBotSeedTest < ActiveSupport::TestCase
    test "channel bot user exists and is not an ai_user" do
      bot = User.find_by(email: "channel@collavre.local")
      assert bot, "Channel bot user must exist"
      refute_predicate bot, :ai_user?
      assert_equal "Channel", bot.name
    end

    test "bot_user returns the existing channel bot" do
      bot = User.find_by!(email: Channel::BOT_EMAIL)

      assert_no_difference -> { User.count } do
        assert_equal bot, Channel.bot_user
      end
    end

    test "bot_user recreates the channel bot when the seed was skipped" do
      User.find_by!(email: Channel::BOT_EMAIL).destroy!

      bot = assert_difference -> { User.count }, 1 do
        Channel.bot_user
      end

      assert_equal Channel::BOT_NAME, bot.name
      assert_predicate bot.email_verified_at, :present?
      refute_predicate bot, :ai_user?
      assert_equal false, bot.searchable
    end

    test "ensure_bot_user! repairs an existing bot without resetting its password" do
      bot = User.find_by!(email: Channel::BOT_EMAIL)
      bot.update_columns(name: "Renamed", llm_vendor: "openai")
      digest = bot.password_digest

      Channel.ensure_bot_user!

      bot.reload
      assert_equal Channel::BOT_NAME, bot.name
      assert_nil bot.llm_vendor
      assert_equal digest, bot.password_digest
    end
  end
end
