require "test_helper"

module Creatives
  class TreeBuilderTest < ActiveSupport::TestCase
    class FakeViewContext
      include Rails.application.routes.url_helpers

      Request = Struct.new(:script_name)
      attr_reader :request

      def initialize(script_name: nil)
        @request = Request.new(script_name)
      end

      def embed_youtube_iframe(_content)
        "<iframe></iframe>"
      end

      def render_creative_description(_creative, fallback: nil)
        fallback
      end

      def render_creative_progress(_creative, select_mode: false, has_children: nil, can_write: nil, can_feedback: nil, unread_count: nil)
        "<progress data-select='#{select_mode}'></progress>"
      end

      def svg_tag(name, className: nil, width: nil, height: nil, **)
        "<svg data-name='#{name}' data-class='#{className}' data-width='#{width}' data-height='#{height}'></svg>"
      end

      def link_to(_path, *args)
        block_given? ? yield : ""
      end

      def creative_path(creative, script_name: nil)
        "#{script_name}/creatives/#{creative.id}"
      end

      def children_creative_path(creative, level:, select_mode:, script_name: nil)
        "#{script_name}/creatives/#{creative.id}/children?level=#{level}&select_mode=#{select_mode}"
      end

      # Engine route proxy
      def collavre
        self
      end
    end

    setup do
      @user = users(:one)
      @view_context = FakeViewContext.new
    end

    test "skips creatives not in allowed_creative_ids" do
      parent = nil
      child = nil
      perform_enqueued_jobs do
        parent = Creative.create!(user: @user, progress: 0.1, description: "Parent")
        child = Creative.create!(user: @user, parent: parent, progress: 0.3, description: "Child")
      end

      # Only child is in allowed_creative_ids (simulating FilterPipeline result without ancestor)
      allowed_ids = Set.new([ child.id.to_s ])
      builder = build_tree_builder(allowed_creative_ids: allowed_ids)
      nodes = builder.build([ parent ])

      # Parent is skipped, child is rendered at level 1
      assert_equal [ child.id ], nodes.pluck(:id)
      assert_equal [ 1 ], nodes.pluck(:level)
    end

    test "shows ancestors when included in allowed_creative_ids" do
      parent = nil
      child = nil
      perform_enqueued_jobs do
        parent = Creative.create!(user: @user, progress: 0.1, description: "Parent")
        child = Creative.create!(user: @user, parent: parent, progress: 0.3, description: "Child")
      end

      # Both parent and child are in allowed_creative_ids (normal FilterPipeline result with ancestors)
      allowed_ids = Set.new([ parent.id.to_s, child.id.to_s ])
      builder = build_tree_builder(allowed_creative_ids: allowed_ids)
      nodes = builder.build([ parent ])

      # Parent is shown at level 1, child is shown as its children
      assert_equal [ parent.id ], nodes.pluck(:id)
      assert_equal [ 1 ], nodes.pluck(:level)
    end

    test "includes inline editor payload data" do
      creative = nil
      perform_enqueued_jobs do
        creative = Creative.create!(user: @user, progress: 0.42, description: "Inline Data")
      end

      builder = build_tree_builder
      nodes = builder.build([ creative ])

      payload = nodes.first[:inline_editor_payload]
      assert_equal creative.effective_description, payload[:description_raw_html]
      assert_in_delta creative.progress, payload[:progress]
      assert_nil payload[:origin_id]
    end

    test "shows the GitHub badge only for GitHub-sourced creatives" do
      github_creative = Creative.create!(
        user: @user,
        description: "GitHub content",
        data: { "source" => { "type" => "github_markdown" } }
      )
      onboarding_creative = Creative.create!(
        user: @user,
        description: "Onboarding content",
        data: {
          "source" => { "type" => "onboarding" },
          "onboarding" => { "session_id" => SecureRandom.uuid, "role" => "card" }
        }
      )

      nodes = build_tree_builder.build([ github_creative, onboarding_creative ])

      assert nodes.find { |node| node[:id] == github_creative.id }[:github_source]
      assert_not nodes.find { |node| node[:id] == onboarding_creative.id }[:github_source]
      assert nodes.find { |node| node[:id] == onboarding_creative.id }[:onboarding_item]
      assert_not nodes.find { |node| node[:id] == github_creative.id }[:onboarding_item]
    end

    test "preserves the engine mount prefix in creative URLs" do
      creative = Creative.create!(user: @user, description: "Mounted")
      @view_context = FakeViewContext.new(script_name: "/collavre")

      node = build_tree_builder.build([ creative ]).sole

      assert_equal "/collavre/creatives/#{creative.id}", node[:link_url]
      assert_equal "/collavre/creatives/#{creative.id}", node[:update_url]
    end

    test "uses the effective origin posture for a linked onboarding root" do
      owner = users(:two)
      root = Creative.create!(
        user: owner,
        description: "Onboarding root",
        data: {
          "kind" => Creative::ONBOARDING_KIND,
          "source" => { "type" => Creative::ONBOARDING_KIND },
          "onboarding" => { "session_id" => SecureRandom.uuid, "role" => "root" }
        }
      )
      perform_enqueued_jobs do
        CreativeShare.create!(creative: root, user: @user, permission: :write, shared_by: owner)
      end
      root.create_linked_creative_for_user(@user)
      linked_root = Creative.find_by!(origin: root, user: @user)

      node = build_tree_builder.build([ linked_root ]).sole

      assert node[:card_layout]
      assert node[:onboarding_item]
      assert_not node[:can_write]
    end

    private

    def build_tree_builder(allowed_creative_ids: nil, params: {})
      Creatives::TreeBuilder.new(
        user: @user,
        params: ActionController::Parameters.new(params),
        view_context: @view_context,
        expanded_state_map: {},
        select_mode: false,
        max_level: 6,
        allowed_creative_ids: allowed_creative_ids
      )
    end
  end
end
