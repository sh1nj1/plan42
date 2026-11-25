# frozen_string_literal: true

require "test_helper"

class Collavre::KollavyIdentityTest < ActiveSupport::TestCase
  test "reserved email rejects registration and profile changes after normalization" do
    user = Collavre::User.new(email: " KOLLAVY@COLLAVRE.LOCAL ", name: "Impostor", password: "password-123")
    refute user.valid?
    assert user.errors.added?(:email, :exclusion, value: Collavre::Kollavy::EMAIL)
    refute users(:two).update(email: Collavre::Kollavy::EMAIL)
    assert users(:two).errors.of_kind?(:email, :exclusion)
  end

  test "seed rejects a pre-existing account without promoting it or sharing inboxes" do
    [ nil, "google" ].each do |vendor|
      user = users(:two)
      user.update_columns(email: Collavre::Kollavy::EMAIL, llm_vendor: vendor)
      before = user.reload.attributes
      assert_nil Collavre::Kollavy.agent
      assert_raises(Collavre::Kollavy::Identity::Conflict) { Collavre::Kollavy.seed! }
      assert_equal before, user.reload.attributes
      refute Collavre::Kollavy.onboard_inbox(users(:one).inbox_creative, user)
      assert_no_difference("Collavre::CreativeShare.where(user: user).count") do
        Collavre::User.create!(email: "new-#{vendor}@example.com", name: "New", password: "password-123")
      end
    end
  end

  test "legacy email squatter cannot discover or directly execute source tools" do
    user = users(:two)
    user.update_columns(email: Collavre::Kollavy::EMAIL, llm_vendor: "google")
    Collavre::Kollavy::SOURCE_TOOLS.each do |name|
      refute Collavre::McpToolRegistry.user_permitted?(name, user)
    end
    Collavre::Current.set(user: user) do
      [ Collavre::Tools::SourceListService.new.call,
        Collavre::Tools::SourceSearchService.new.call(query: "class"),
        Collavre::Tools::SourceReadService.new.call(path: "config/routes.rb") ].each do |result|
        assert_equal({ error: I18n.t("collavre.mcp_tools.unavailable") }, result)
      end
    end
  end

  test "system identity is immutable and seed remains idempotent" do
    user = Collavre::Kollavy.seed!
    assert user.system_agent?
    digest = user.password_digest
    assert_equal user, Collavre::Kollavy.seed!
    assert_equal digest, user.reload.password_digest
    assert_raises(ActiveRecord::ReadonlyAttributeError) { user.system_agent = false }
    refute Collavre::Kollavy::Identity.agent?(nil)
    refute Collavre::Kollavy::Identity.agent?(Collavre::User.new(email: Collavre::Kollavy::EMAIL, system_agent: true))
    refute Collavre::Kollavy::Identity.agent?(users(:one))
  end
end
