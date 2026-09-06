require "test_helper"

module Creatives
  class TreeBuilderTest < ActiveSupport::TestCase
    class FakeViewContext
      include Rails.application.routes.url_helpers

      def embed_youtube_iframe(_content)
        "<iframe></iframe>"
      end

      def render_creative_progress(_creative, select_mode: false, has_children: nil, can_write: nil, can_feedback: nil, unread_count: nil, cron_tasks: [], can_delete_cron: nil)
        "<progress data-select='#{select_mode}'></progress><cron-badge count='#{cron_tasks.size}' can-delete='#{can_delete_cron}'></cron-badge>"
      end

      def svg_tag(name, className: nil, width: nil, height: nil)
        "<svg data-name='#{name}' data-class='#{className}' data-width='#{width}' data-height='#{height}'></svg>"
      end

      def link_to(_path, *args)
        block_given? ? yield : ""
      end

      def creative_path(creative)
        "/creatives/#{creative.id}"
      end

      def children_creative_path(creative, level:, select_mode:)
        "/creatives/#{creative.id}/children?level=#{level}&select_mode=#{select_mode}"
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

    test "includes cron badge details when the cron filter is active" do
      creative = Creative.create!(user: @user, progress: 0, description: "Scheduled")
      task = SolidQueue::RecurringTask.create!(
        key: "cron_#{creative.id}_#{SecureRandom.hex(4)}",
        class_name: "Collavre::CronActionJob",
        schedule: "0 9 * * *",
        static: false,
        arguments: []
      )

      nodes = build_tree_builder(params: { has_cron: "true" }).build([ creative ])

      assert_includes nodes.first.dig(:templates, :progress_html), "<cron-badge count='1'"
    ensure
      task&.destroy!
    end

    test "allows cron deletion for a writer when source content is read-only" do
      source_type = "tree_builder_read_only_source"
      Creative.register_read_only_source(source_type)
      owner = users(:two)
      creative = Creative.create!(
        user: owner,
        progress: 0,
        description: "Read-only scheduled",
        data: { "source" => { "type" => source_type } }
      )
      CreativeShare.create!(creative: creative, user: @user, shared_by: owner, permission: :write)
      task = SolidQueue::RecurringTask.create!(
        key: "cron_#{creative.id}_#{SecureRandom.hex(4)}",
        class_name: "Collavre::CronActionJob",
        schedule: "0 9 * * *",
        static: false,
        arguments: []
      )

      node = build_tree_builder(params: { has_cron: "true" }).build([ creative ]).first

      assert_equal false, node[:can_write]
      assert_includes node.dig(:templates, :progress_html), "can-delete='true'"
    ensure
      task&.destroy!
      Creative.read_only_source_types.delete(source_type) if source_type
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
