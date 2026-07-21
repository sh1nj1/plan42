require "test_helper"

module Collavre
  class UserProfileSystemPromptTest < ActiveSupport::TestCase
    test "sync mirrors the agent system prompt into the profile description" do
      agent = Collavre::User.create!(name: "NamedBot", email: "syncbot1@ai.local",
                                     password: "password123", llm_vendor: "google",
                                     system_prompt: "REAL PROMPT")
      # after_create seeds the profile description with the name — the bug we fix.
      assert_equal "NamedBot", agent.profile_creative.description
      agent.sync_profile_system_prompt!
      assert_equal "REAL PROMPT", agent.profile_creative.reload.description
    end

    test "sync is a no-op for human users" do
      human = Collavre::User.create!(name: "Human", email: "human1@example.com", password: "password123")
      human.sync_profile_system_prompt!
      assert_equal "Human", human.profile_creative.description
    end

    test "sync is a no-op when the agent has no system prompt" do
      agent = Collavre::User.create!(name: "Blanky", email: "syncbot2@ai.local",
                                     password: "password123", llm_vendor: "google")
      agent.sync_profile_system_prompt!
      assert_equal "Blanky", agent.profile_creative.description
    end
  end
end
