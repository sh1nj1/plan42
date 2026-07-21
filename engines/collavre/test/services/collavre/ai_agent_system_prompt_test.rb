# frozen_string_literal: true

require "test_helper"

module Collavre
  class AiAgentSystemPromptTest < ActiveSupport::TestCase
    setup do
      @agent = Collavre::User.create!(name: "Bot", email: "bot2@example.com",
                                      password: "password123", llm_vendor: "google",
                                      system_prompt: "COLUMN PROMPT")
    end

    test "prefers profile description over the column" do
      @agent.profile_creative.update!(description: "PROFILE PROMPT")
      svc = Collavre::AiAgentService.allocate
      svc.instance_variable_set(:@agent, @agent)
      svc.instance_variable_set(:@creative, nil)
      assert_includes svc.send(:render_system_prompt, {}), "PROFILE PROMPT"
    end

    test "falls back to the column when profile description is blank" do
      # Creative#description carries a presence validation (via closure_tree's
      # name_column), so update! rejects a blank value. Use update_column to
      # bypass validation and simulate a legacy/blank row for this test.
      @agent.profile_creative.update_column(:description, "")
      svc = Collavre::AiAgentService.allocate
      svc.instance_variable_set(:@agent, @agent)
      svc.instance_variable_set(:@creative, nil)
      assert_includes svc.send(:render_system_prompt, {}), "COLUMN PROMPT"
    end
  end
end
