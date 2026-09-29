# frozen_string_literal: true

require "test_helper"

class Collavre::KollavyTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @inbox = Collavre::Creative.inbox_for(@user)
  end

  def seed
    Collavre::Kollavy.seed!
  end

  test "agent is nil before seeding" do
    assert_nil Collavre::Kollavy.agent
    refute Collavre::Kollavy.onboard_inbox(@inbox)
  end

  test "seed creates the configured agent with its avatar" do
    kollavy = seed

    assert_equal kollavy, Collavre::Kollavy.agent
    assert_equal "Kollavy", kollavy.name
    assert kollavy.ai_user?
    assert kollavy.searchable?
    assert_nil kollavy.routing_expression
    assert_equal Collavre::Kollavy::TOOLS, kollavy.tools
    assert_includes kollavy.tools, "collavre_source_read"
    assert Collavre::ToolApprovalPolicy.agent_requires_approval?(kollavy, "creative_update_service")
    refute Collavre::ToolApprovalPolicy.agent_requires_approval?(kollavy, "creative_retrieval_service")
    assert_equal 20, kollavy.chat_history_limit
    assert kollavy.avatar.attached?
    assert_equal "image/png", kollavy.avatar.content_type
  end

  test "seed is idempotent and restores edited settings" do
    kollavy = seed
    blob_id = kollavy.avatar.blob.id
    kollavy.update!(name: "Renamed", tools: [ "creative_retrieval_service" ])

    again = seed

    assert_equal kollavy.id, again.id
    assert_equal 1, Collavre::User.where(email: Collavre::Kollavy::EMAIL).count
    assert_equal "Kollavy", again.name
    assert_equal Collavre::Kollavy::TOOLS, again.tools
    assert_equal blob_id, again.avatar.blob.id, "an unchanged avatar is not re-uploaded"
    assert_equal 1, Collavre::CreativeShare.where(creative: @inbox, user: again).count
  end

  test "seed replaces an outdated avatar" do
    kollavy = seed
    kollavy.avatar.attach(io: StringIO.new("old"), filename: "old.png", content_type: "image/png")

    assert_equal "kollavy.png", seed.avatar.filename.to_s
  end

  test "seed shares every human inbox and pins Kollavy on Main once" do
    kollavy = seed

    share = Collavre::CreativeShare.find_by!(creative: @inbox, user: kollavy)
    assert share.feedback?
    assert_equal @user, share.shared_by
    assert_equal kollavy, @inbox.main_topic.primary_agent
    assert @inbox.reload.data[Collavre::Kollavy::ONBOARDED_KEY].present?
    assert Collavre::Topic.primary_agent_assignable?(@inbox, kollavy, topic: @inbox.main_topic)
  end

  test "a user's later choice survives re-seeding" do
    kollavy = seed
    @inbox.main_topic.update!(primary_agent: nil)
    Collavre::CreativeShare.find_by!(creative: @inbox, user: kollavy).destroy!

    seed

    assert_nil @inbox.main_topic.reload.primary_agent
    refute Collavre::CreativeShare.exists?(creative: @inbox, user: kollavy)
  end

  test "an existing primary agent is kept" do
    other = users(:ai_bot)
    Collavre::CreativeShare.create!(creative: @inbox, user: other, permission: :feedback)
    @inbox.main_topic.update!(primary_agent: other)

    seed

    assert_equal other, @inbox.main_topic.reload.primary_agent
    assert @inbox.reload.data[Collavre::Kollavy::ONBOARDED_KEY].present?
  end

  test "an existing lower share is left alone and Kollavy is not pinned" do
    kollavy = Collavre::User.create!(system_agent: true, email: Collavre::Kollavy::EMAIL, name: "Kollavy", password: "password-123",
                                     llm_vendor: "google", llm_model: "m")
    Collavre::CreativeShare.create!(creative: @inbox, user: kollavy, permission: :read)

    assert Collavre::Kollavy.onboard_inbox(@inbox, kollavy)

    assert Collavre::CreativeShare.find_by!(creative: @inbox, user: kollavy).read?
    assert_nil @inbox.main_topic.reload.primary_agent
  end

  test "a concurrent share insert is reused" do
    kollavy = Collavre::User.create!(system_agent: true, email: Collavre::Kollavy::EMAIL, name: "Kollavy", password: "password-123",
                                     llm_vendor: "google", llm_model: "m")
    existing = Collavre::CreativeShare.create!(creative: @inbox, user: kollavy, permission: :feedback)
    Collavre::CreativeShare.stub(:find_or_create_by!, ->(*) { raise ActiveRecord::RecordNotUnique }) do
      assert Collavre::Kollavy.onboard_inbox(@inbox, kollavy)
    end
    assert_equal existing, Collavre::CreativeShare.find_by(creative: @inbox, user: kollavy)
  end

  test "agent and channel bot inboxes are skipped" do
    kollavy = seed
    bot = Collavre::User.find_by(email: Collavre::Channel::BOT_EMAIL) ||
          Collavre::User.create!(email: Collavre::Channel::BOT_EMAIL, name: "Channel", password: "password-123")
    bot_inbox = Collavre::Creative.inbox_for(bot)
    agent_inbox = Collavre::Creative.inbox_for(users(:ai_bot))
    plain = Collavre::Creative.create!(user: @user, description: "Not an inbox")

    [ bot_inbox, agent_inbox, plain ].each { |c| refute Collavre::Kollavy.onboard_inbox(c, kollavy) }
    refute Collavre::CreativeShare.exists?(creative: [ bot_inbox, agent_inbox, plain ], user: kollavy)
  end

  test "new users are onboarded when their inbox is created" do
    kollavy = seed
    user = Collavre::User.create!(email: "fresh@example.com", name: "Fresh", password: "password-123")

    inbox = user.inbox_creative
    assert_equal kollavy, inbox.main_topic.primary_agent
    assert Collavre::CreativeShare.find_by!(creative: inbox, user: kollavy).feedback?
  end

  test "an onboarding failure does not block inbox creation" do
    seed
    Collavre::Kollavy.stub(:onboard_inbox, ->(*) { raise "boom" }) do
      user = Collavre::User.create!(email: "fail@example.com", name: "Fail", password: "password-123")
      assert Collavre::Creative.inboxes.exists?(user: user)
    end
  end

  test "system prompt answers in the sender's locale when known" do
    with_locale = Collavre::AiSystemPromptRenderer.render(template: Collavre::Kollavy::SYSTEM_PROMPT,
                                                          context: { "sender" => { "locale" => "ko" } })
    without = Collavre::AiSystemPromptRenderer.render(template: Collavre::Kollavy::SYSTEM_PROMPT, context: {})

    assert_includes with_locale, %(preferred language: "ko")
    assert_includes without, "language the user wrote in"
  end
end
