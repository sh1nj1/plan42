# frozen_string_literal: true

require "test_helper"

module Collavre
  class AiAgentSystemPromptTest < ActiveSupport::TestCase
    setup do
      @agent = Collavre::User.create!(name: "Bot", email: "bot2@example.com",
                                      password: "password123", llm_vendor: "google",
                                      system_prompt: "COLUMN PROMPT")
    end

    test "prefers the profile markdown_source over the column" do
      @agent.profile_creative.update!(content_type_input: "markdown", markdown_source: "PROFILE PROMPT")
      svc = Collavre::AiAgentService.allocate
      svc.instance_variable_set(:@agent, @agent)
      svc.instance_variable_set(:@creative, nil)
      assert_includes svc.send(:render_system_prompt, {}), "PROFILE PROMPT"
    end

    test "renders a tag-bearing prompt verbatim, uncorrupted by the sanitizer" do
      prompt = "Wrap reasoning in <thinking>...</thinking>. count < 5 and result > 3."
      @agent.profile_creative.update!(content_type_input: "markdown", markdown_source: prompt)
      svc = Collavre::AiAgentService.allocate
      svc.instance_variable_set(:@agent, @agent)
      svc.instance_variable_set(:@creative, nil)
      out = svc.send(:render_system_prompt, {})
      assert_includes out, "<thinking>...</thinking>"
      assert_includes out, "count < 5 and result > 3"
    end

    test "falls back to the column when the profile has no markdown_source" do
      # A profile creative not yet backfilled has no data["markdown_source"];
      # render must fall back to the legacy column, not the name-seeded description.
      assert_nil @agent.profile_creative.data&.dig("markdown_source")
      svc = Collavre::AiAgentService.allocate
      svc.instance_variable_set(:@agent, @agent)
      svc.instance_variable_set(:@creative, nil)
      assert_includes svc.send(:render_system_prompt, {}), "COLUMN PROMPT"
    end

    test "a normally created agent renders its prompt after sync, not its name" do
      agent = Collavre::User.create!(name: "RenderBot", email: "renderbot@ai.local",
                                     password: "password123", llm_vendor: "google",
                                     system_prompt: "SYSTEM PROMPT TEXT")
      agent.sync_profile_system_prompt!
      svc = Collavre::AiAgentService.allocate
      svc.instance_variable_set(:@agent, agent)
      svc.instance_variable_set(:@creative, nil)
      out = svc.send(:render_system_prompt, {})
      assert_includes out, "SYSTEM PROMPT TEXT"
      refute_includes out, "RenderBot"
    end
  end
end
