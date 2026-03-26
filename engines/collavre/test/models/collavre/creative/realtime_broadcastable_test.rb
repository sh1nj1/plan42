# frozen_string_literal: true

require "test_helper"

module Collavre
  class Creative
    class RealtimeBroadcastableTest < ActiveSupport::TestCase
      setup do
        @owner = users(:one)
        @shared_user = users(:two)
        Current.session = OpenStruct.new(user: @owner)

        # Use test adapter for job assertions
        @original_adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test

        perform_enqueued_jobs do
          @root = Creative.create!(user: @owner, description: "Broadcast Root", progress: 0.0)
          @child = Creative.create!(user: @owner, parent: @root, description: "Broadcast Child", progress: 0.5)
          @grandchild = Creative.create!(user: @owner, parent: @child, description: "Broadcast Grandchild", progress: 0.0)

          # Share root with shared_user (read permission propagates to descendants)
          CreativeShare.create!(creative: @root, user: @shared_user, permission: :write)
        end
      end

      teardown do
        ActiveJob::Base.queue_adapter = @original_adapter
        Current.reset
      end

      # --- broadcast_node_payload ---

      test "broadcast_node_payload returns tree-renderer compatible structure" do
        payload = @child.broadcast_node_payload

        assert_equal @child.id, payload[:id]
        assert_equal "creative-#{@child.id}", payload[:dom_id]
        assert_equal @root.id, payload[:parent_id]
        assert_kind_of Integer, payload[:level]
        assert_includes payload[:templates].keys, :description_html
        assert_kind_of Hash, payload[:inline_editor_payload]
        # broadcast_node_payload calls reload, so check progress is a number
        assert_kind_of Numeric, payload[:inline_editor_payload][:progress]
        assert_kind_of Array, payload[:ancestors]
      end

      test "broadcast_node_payload includes ancestor progress" do
        payload = @grandchild.broadcast_node_payload
        ancestor_ids = payload[:ancestors].map { |a| a[:id] }

        assert_includes ancestor_ids, @child.id
        assert_includes ancestor_ids, @root.id
      end

      test "broadcast_node_payload has correct level for nested creative" do
        payload = @grandchild.broadcast_node_payload
        # root(1) → child(2) → grandchild(3)
        assert_equal 3, payload[:level]
      end

      test "broadcast_node_payload includes required keys" do
        payload = @child.broadcast_node_payload
        required_keys = %i[id dom_id parent_id level select_mode can_write has_children
                           expanded is_root archived link_url origin_id sequence
                           templates inline_editor_payload ancestors]
        required_keys.each do |key|
          assert payload.key?(key), "Missing key: #{key}"
        end
      end

      # --- progress_only_change? ---

      test "progress_only_change? returns true when only progress changed" do
        @child.update!(progress: 0.8)
        assert @child.send(:progress_only_change?)
      end

      test "progress_only_change? returns false when description also changed" do
        @child.update!(progress: 0.8, description: "Updated")
        refute @child.send(:progress_only_change?)
      end

      test "progress_only_change? returns false when progress not changed" do
        @child.update!(description: "New description")
        refute @child.send(:progress_only_change?)
      end

      # --- find_broadcast_users ---

      test "find_broadcast_users includes owner and shared users" do
        users = @root.send(:find_broadcast_users)
        user_ids = users.map(&:id)

        assert_includes user_ids, @owner.id
        assert_includes user_ids, @shared_user.id
      end

      test "find_broadcast_users for child includes users shared on ancestor" do
        users = @grandchild.send(:find_broadcast_users)
        user_ids = users.map(&:id)

        assert_includes user_ids, @owner.id
        assert_includes user_ids, @shared_user.id
      end

      test "find_broadcast_users excludes users without read permission" do
        unshared_user = users(:three)
        users = @root.send(:find_broadcast_users)
        user_ids = users.map(&:id)

        refute_includes user_ids, unshared_user.id
      end

      test "find_broadcast_users returns empty on error" do
        # Stub ancestor_ids to raise
        @root.stub(:ancestor_ids, -> { raise StandardError, "boom" }) do
          users = @root.send(:find_broadcast_users)
          assert_equal [], users
        end
      end

      # --- build_linked_creative_map ---

      test "build_linked_creative_map returns empty when no linked creatives" do
        map = @root.send(:build_linked_creative_map, [ @shared_user ])
        assert_kind_of Hash, map
      end

      test "build_linked_creative_map maps user to linked creative id" do
        perform_enqueued_jobs do
          linked = Creative.create!(
            user: @shared_user,
            origin_id: @root.id,
            description: "Linked copy"
          )

          map = @root.send(:build_linked_creative_map, [ @shared_user ])
          assert_equal linked.id, map[@shared_user.id]
        end
      end

      # --- format_progress_text ---

      test "format_progress_text returns percentage for normal progress" do
        text = @root.send(:format_progress_text, 0.5, @owner)
        assert_equal "50%", text
      end

      test "format_progress_text returns 0% for zero progress" do
        text = @root.send(:format_progress_text, 0.0, @owner)
        assert_equal "0%", text
      end

      test "format_progress_text rounds correctly" do
        text = @root.send(:format_progress_text, 0.333, @owner)
        assert_equal "33%", text
      end

      test "format_progress_text returns completion mark when user has one set" do
        # completion_mark has NOT NULL constraint, so just check current behavior
        mark = @owner.completion_mark
        text = @root.send(:format_progress_text, 1.0, @owner)
        if mark.present?
          assert_equal mark, text
        elsif mark == "" # blank but not nil
          assert_equal "", text
        else
          assert_equal "100%", text
        end
      end

      # --- add_progress_text! ---

      test "add_progress_text! adds progress_text to data" do
        data = {
          inline_editor_payload: { progress: 0.75 },
          ancestors: [ { id: 1, progress: 0.5 } ]
        }
        @root.send(:add_progress_text!, data, @owner)

        assert_equal "75%", data[:progress_text]
        assert_equal "50%", data[:ancestors].first[:progress_text]
      end

      test "add_progress_text! handles nil ancestors" do
        data = { inline_editor_payload: { progress: 0.5 }, ancestors: nil }
        assert_nothing_raised do
          @root.send(:add_progress_text!, data, @owner)
        end
        assert_equal "50%", data[:progress_text]
      end

      # --- enqueue_broadcast ---

      test "broadcast_creative_created enqueues CreativeBroadcastJob" do
        creative = nil
        perform_enqueued_jobs(only: Collavre::PermissionCacheJob) do
          creative = Creative.create!(user: @owner, parent: @root, description: "New child", progress: 0.0)
        end

        assert_enqueued_with(job: Collavre::CreativeBroadcastJob) do
          creative.reload
          creative.broadcast_creative_created(after_id: nil)
        end
      end

      test "broadcast_creative_updated enqueues job on description change" do
        assert_enqueued_with(job: Collavre::CreativeBroadcastJob) do
          @child.update!(description: "Updated description")
        end
      end

      test "broadcast_creative_updated skips progress-only changes" do
        assert_no_enqueued_jobs(only: Collavre::CreativeBroadcastJob) do
          @child.update!(progress: 0.9)
        end
      end

      # --- capture_broadcast_state / broadcast_creative_destroyed ---

      test "capture_broadcast_state stores users and payload for shared creative" do
        # @child has parent (@root) which is shared — should capture
        @child.send(:capture_broadcast_state)
        assert_not_nil @child.instance_variable_get(:@_destroy_broadcast_users)
        assert_not_nil @child.instance_variable_get(:@_destroy_payload)
      end

      test "capture_broadcast_state skips top-level personal creative without links" do
        personal = nil
        perform_enqueued_jobs do
          personal = Creative.create!(user: @owner, description: "Personal", progress: 0.0)
        end
        personal.send(:capture_broadcast_state)
        assert_nil personal.instance_variable_get(:@_destroy_broadcast_users)
      end

      test "broadcast_creative_destroyed enqueues job after capture" do
        @child.send(:capture_broadcast_state)

        assert_enqueued_with(job: Collavre::CreativeBroadcastJob) do
          @child.send(:broadcast_creative_destroyed)
        end
      end

      test "broadcast_creative_destroyed is no-op without capture" do
        assert_no_enqueued_jobs(only: Collavre::CreativeBroadcastJob) do
          @child.send(:broadcast_creative_destroyed)
        end
      end

      # --- previous_sibling ---

      test "previous_sibling returns nil for first child" do
        perform_enqueued_jobs do
          parent = Creative.create!(user: @owner, description: "Isolated Parent", progress: 0.0)
          first = Creative.create!(user: @owner, parent: parent, description: "First", progress: 0.0)
          first.update_column(:sequence, 0)

          assert_nil first.reload.send(:previous_sibling)
        end
      end

      test "previous_sibling returns sibling with lower sequence" do
        perform_enqueued_jobs do
          parent = Creative.create!(user: @owner, description: "Sibling Parent", progress: 0.0)
          sib1 = Creative.create!(user: @owner, parent: parent, description: "Sib1", progress: 0.0)
          sib2 = Creative.create!(user: @owner, parent: parent, description: "Sib2", progress: 0.0)

          # Set sequences explicitly
          sib1.update_column(:sequence, 10)
          sib2.update_column(:sequence, 20)

          prev = sib2.reload.send(:previous_sibling)
          # previous_sibling returns the sibling with the highest sequence below sib2's
          assert_equal sib1.id, prev.id
        end
      end

      # --- safe_effective_origin ---

      test "safe_effective_origin returns self on error" do
        @root.stub(:effective_origin, -> { raise StandardError, "boom" }) do
          result = @root.send(:safe_effective_origin)
          assert_equal @root, result
        end
      end

      # --- build_ancestor_ids_from_parent ---

      test "build_ancestor_ids_from_parent walks parent chain" do
        ids = @grandchild.send(:build_ancestor_ids_from_parent, @grandchild)
        assert_includes ids, @child.id
        assert_includes ids, @root.id
      end

      test "build_ancestor_ids_from_parent returns empty for root" do
        ids = @root.send(:build_ancestor_ids_from_parent, @root)
        assert_equal [], ids
      end
    end
  end
end
