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

    test "sync stores an inline data-URI image in the prompt losslessly" do
      # A prompt may legitimately reference an inline data-URI image outside a
      # code span. The Markdown save path rewrites data-URI images into Active
      # Storage blob paths (to avoid duplicate blobs on editor re-render), but
      # effective_system_prompt sends markdown_source straight to the LLM, so the
      # agent must receive the exact prompt the user entered — not a blob path.
      prompt = "Reference logo you must watermark: " \
               "![logo](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==)"
      agent = Collavre::User.create!(name: "ImgBot", email: "imgbot@ai.local",
                                     password: "password123", llm_vendor: "google",
                                     system_prompt: prompt)
      agent.sync_profile_system_prompt!
      stored = agent.profile_creative.reload.data["markdown_source"]
      assert_equal prompt, stored
      refute_includes stored, "/rails/active_storage/blobs"
      refute_includes stored, "/public-assets/blobs"
      # The canonical prompt reaches every reader verbatim.
      assert_equal prompt, agent.reload.effective_system_prompt
    end

    test "editing the profile creative directly keeps a data-URI prompt verbatim" do
      # The sync path sets skip_data_uri_rewrite, but a *direct* edit of the
      # profile Creative through the normal Markdown save path does not — yet its
      # markdown_source is equally LLM-bound. The data-URI rewrite must not fire
      # for profile creatives regardless of caller (sync vs direct editor save).
      prompt = "Watermark with this: " \
               "![logo](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==)"
      agent = Collavre::User.create!(name: "DirectBot", email: "directbot@ai.local",
                                     password: "password123", llm_vendor: "google")
      # Simulate a direct Creative-editor save: Markdown mode, no skip flag set.
      agent.profile_creative.update!(content_type_input: "markdown", markdown_source: prompt)
      stored = agent.profile_creative.reload.data["markdown_source"]
      assert_equal prompt, stored
      refute_includes stored, "/rails/active_storage/blobs"
      refute_includes stored, "/public-assets/blobs"
      assert_equal prompt, agent.reload.effective_system_prompt
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

    test "clearing the system prompt drops the stale markdown_source" do
      agent = Collavre::User.create!(name: "ClearBot", email: "clearbot@ai.local",
                                     password: "password123", llm_vendor: "google",
                                     system_prompt: "FIRST PROMPT")
      agent.sync_profile_system_prompt!
      assert_equal "FIRST PROMPT", agent.profile_creative.reload.data["markdown_source"]

      # Admin blanks the prompt textarea — the old prompt must NOT stay authoritative.
      agent.update!(system_prompt: "")
      agent.sync_profile_system_prompt!
      assert_nil agent.profile_creative.reload.data&.dig("markdown_source")

      # The old rendered prompt must not linger as the visible profile description;
      # it is reseeded back to the name so it isn't searchable/shown on the root.
      assert_equal "ClearBot", agent.profile_creative.reload.description

      svc = Collavre::AiAgentService.allocate
      svc.instance_variable_set(:@agent, agent)
      svc.instance_variable_set(:@creative, nil)
      refute_includes svc.send(:render_system_prompt, {}), "FIRST PROMPT"
    end

    test "effective_system_prompt prefers profile markdown_source over the legacy column" do
      agent = Collavre::User.create!(name: "EffBot", email: "effbot@ai.local",
                                     password: "password123", llm_vendor: "google",
                                     system_prompt: "LEGACY COLUMN")
      # Before sync the column is the only source.
      assert_equal "LEGACY COLUMN", agent.effective_system_prompt
      # A direct profile edit (no column write) must take effect for all readers.
      agent.profile_creative.update!(content_type_input: "markdown", markdown_source: "EDITED IN PROFILE")
      assert_equal "EDITED IN PROFILE", agent.reload.effective_system_prompt
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
