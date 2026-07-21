require "test_helper"

module Collavre
  class UserProfileSystemPromptTest < ActiveSupport::TestCase
    test "sync mirrors the agent system prompt into the profile markdown_source" do
      agent = Collavre::User.create!(name: "NamedBot", email: "syncbot1@ai.local",
                                     password: "password123", llm_vendor: "google",
                                     system_prompt: "REAL PROMPT")
      # after_create seeds the profile description with the name — the bug we fix.
      assert_equal "NamedBot", agent.profile_creative.description
      agent.sync_profile_system_prompt!
      assert_equal "REAL PROMPT", agent.profile_creative.reload.data["markdown_source"]
    end

    test "sync stores prompts with tags and angle brackets losslessly" do
      # Prompts routinely contain <thinking>, tool tags, and < > &. These MUST
      # survive verbatim in markdown_source; the sanitized `description` would
      # strip/entity-escape them, which is exactly why the prompt is NOT stored
      # in description.
      prompt = "Wrap reasoning in <thinking>...</thinking>. " \
               "When count < 5 and result > 3 emit <tool_call>x</tool_call>. Use JSON & XML."
      agent = Collavre::User.create!(name: "TagBot", email: "tagbot@ai.local",
                                     password: "password123", llm_vendor: "google",
                                     system_prompt: prompt)
      agent.sync_profile_system_prompt!
      assert_equal prompt, agent.profile_creative.reload.data["markdown_source"]
    end

    test "sync is idempotent and does not re-write an unchanged prompt" do
      agent = Collavre::User.create!(name: "IdemBot", email: "idembot@ai.local",
                                     password: "password123", llm_vendor: "google",
                                     system_prompt: "STABLE PROMPT")
      agent.sync_profile_system_prompt!
      before = agent.profile_creative.reload.updated_at
      agent.sync_profile_system_prompt!
      assert_equal before, agent.profile_creative.reload.updated_at
    end

    test "sync is a no-op for human users" do
      human = Collavre::User.create!(name: "Human", email: "human1@example.com", password: "password123")
      human.sync_profile_system_prompt!
      assert_nil human.profile_creative.data&.dig("markdown_source")
      assert_equal "Human", human.profile_creative.description
    end

    test "sync is a no-op when the agent has no system prompt" do
      agent = Collavre::User.create!(name: "Blanky", email: "syncbot2@ai.local",
                                     password: "password123", llm_vendor: "google")
      agent.sync_profile_system_prompt!
      assert_nil agent.profile_creative.data&.dig("markdown_source")
      assert_equal "Blanky", agent.profile_creative.description
    end
  end
end
