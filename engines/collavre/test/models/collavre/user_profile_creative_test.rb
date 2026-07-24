require "test_helper"

module Collavre
  class UserProfileCreativeTest < ActiveSupport::TestCase
    test "human user gets a profile creative on create" do
      u = Collavre::User.create!(name: "Human", email: "h@example.com", password: "password123")
      assert_equal "profile", u.profile_creative.data["kind"]
    end

    test "AI agent also gets a profile creative on create" do
      a = Collavre::User.create!(name: "Bot", email: "bot@example.com", password: "password123", llm_vendor: "google")
      assert a.ai_user?
      assert_equal "profile", a.profile_creative.data["kind"]
    end

    test "AI agent profile creative is shared with its creator as admin" do
      creator = Collavre::User.create!(name: "Maker", email: "maker@example.com", password: "password123")
      agent = Collavre::User.create!(name: "Bot", email: "bot2@example.com", password: "password123",
                                     llm_vendor: "google", created_by_id: creator.id)

      profile = agent.profile_creative
      share = Collavre::CreativeShare.find_by(creative: profile, user: creator)

      assert share, "expected the creator to be shared on the agent profile creative"
      assert_equal "admin", share.permission
      assert profile.has_permission?(creator, :admin)
      # The agent still owns its own profile; the creator reaches it via the share.
      assert_equal agent.id, profile.user_id
    end

    test "human user profile creative is not shared with whoever created them" do
      inviter = Collavre::User.create!(name: "Inviter", email: "inviter@example.com", password: "password123")
      human = Collavre::User.create!(name: "Invitee", email: "invitee@example.com", password: "password123",
                                     created_by_id: inviter.id)

      profile = human.profile_creative

      assert_nil Collavre::CreativeShare.find_by(creative: profile, user: inviter),
                 "a human's personal profile must not be exposed to whoever created their account"
    end

    test "agent without a creator gets no profile share" do
      agent = Collavre::User.create!(name: "Orphan bot", email: "bot3@example.com", password: "password123",
                                     llm_vendor: "google")

      assert_empty Collavre::CreativeShare.where(creative: agent.profile_creative)
    end

    test "removing the creator share is not undone by a later profile_for" do
      creator = Collavre::User.create!(name: "Maker", email: "maker2@example.com", password: "password123")
      agent = Collavre::User.create!(name: "Bot", email: "bot4@example.com", password: "password123",
                                     llm_vendor: "google", created_by_id: creator.id)
      profile = agent.profile_creative
      Collavre::CreativeShare.find_by(creative: profile, user: creator).destroy!

      Collavre::Creative.profile_for(agent)

      assert_nil Collavre::CreativeShare.find_by(creative: profile, user: creator),
                 "a deliberately removed share must not be resurrected"
    end

    test "creator share does not post a self-referential inbox notification" do
      creator = Collavre::User.create!(name: "Maker", email: "maker3@example.com", password: "password123")
      Collavre::Current.user = creator
      inbox = Collavre::Creative.inbox_for(creator)
      before = Collavre::Comment.where(creative: inbox).count

      Collavre::User.create!(name: "Bot", email: "bot5@example.com", password: "password123",
                             llm_vendor: "google", created_by_id: creator.id)

      assert_equal before, Collavre::Comment.where(creative: inbox).count,
                   "the creator should not be told they shared something with themselves"
    ensure
      Collavre::Current.user = nil
    end
  end
end
