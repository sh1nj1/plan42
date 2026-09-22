# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    class WorkflowPolicyTest < ActiveSupport::TestCase
      setup do
        @creative = creatives(:tshirt)
        @user = users(:one)
        @agent = users(:ai_bot)
        @topic = Topic.create!(name: "Workflow Policy Topic", creative: @creative, user: @user)
        @context = {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => @topic.id }
        }
      end

      test "defaults workflow routing to shadow" do
        assert_equal "shadow", resolver.workflow_routing_mode
      end

      %w[off shadow on].each do |mode|
        test "accepts #{mode} workflow routing mode" do
          create_policy(config: { "workflow_routing" => mode })

          assert_equal mode, resolver.workflow_routing_mode
        end
      end

      test "falls back to shadow for an invalid workflow routing mode" do
        create_policy(config: { "workflow_routing" => "invalid" })

        assert_equal "shadow", resolver.workflow_routing_mode
      end

      test "ignores disabled workflow routing policies" do
        create_policy(enabled: false, config: { "workflow_routing" => "on" })

        assert_equal "shadow", resolver.workflow_routing_mode
      end

      test "topic workflow routing policy overrides creative and global policies" do
        create_policy(config: { "workflow_routing" => "off" })
        create_policy(scope: @creative, config: { "workflow_routing" => "on" })
        create_policy(scope: @topic, config: { "workflow_routing" => "shadow" })

        assert_equal "shadow", resolver.workflow_routing_mode
      end

      test "creative workflow routing policy overrides a global off mode" do
        create_policy(config: { "workflow_routing" => "off" })
        create_policy(scope: @creative, config: { "workflow_routing" => "on" })

        assert_equal "on", resolver.workflow_routing_mode
      end

      test "ignores User-scoped workflow routing policies" do
        create_policy(scope: @agent, config: { "workflow_routing" => "on" })

        assert_equal "shadow", resolver.workflow_routing_mode
      end

      private

      def resolver
        PolicyResolver.new(@context)
      end

      def create_policy(scope: nil, enabled: true, config:)
        OrchestratorPolicy.create!(
          policy_type: "matching",
          scope_type: scope&.class&.name&.demodulize,
          scope_id: scope&.id,
          enabled: enabled,
          config: config
        )
      end
    end
  end
end
