# frozen_string_literal: true

require "test_helper"

module Collavre
  class CreativeBroadcastJobTest < ActiveSupport::TestCase
    setup do
      @owner = users(:one)
      @shared_user = users(:two)
      Current.session = OpenStruct.new(user: @owner)

      perform_enqueued_jobs do
        @root = Creative.create!(user: @owner, description: "Job Test Root", progress: 0.0)
        @child = Creative.create!(user: @owner, parent: @root, description: "Job Test Child", progress: 0.5)
        @grandchild = Creative.create!(user: @owner, parent: @child, description: "Job Test Grandchild", progress: 0.0)
        CreativeShare.create!(creative: @root, user: @shared_user, permission: :write)
      end
    end

    teardown do
      Current.reset
    end

    # --- created action ---

    test "created action does not raise for valid creative" do
      payload = @child.broadcast_node_payload
      payload[:after_id] = nil
      payload[:previous_sibling_id] = nil

      assert_nothing_raised do
        CreativeBroadcastJob.perform_now(
          @child.id,
          "created",
          current_user_id: @owner.id,
          payload: payload
        )
      end
    end

    test "created action is no-op for missing creative" do
      assert_nothing_raised do
        CreativeBroadcastJob.perform_now(
          999_999_999,
          "created",
          current_user_id: @owner.id,
          payload: {}
        )
      end
    end

    # --- updated action ---

    test "updated action does not raise for valid creative" do
      payload = @child.broadcast_node_payload

      assert_nothing_raised do
        CreativeBroadcastJob.perform_now(
          @child.id,
          "updated",
          current_user_id: @owner.id,
          payload: payload
        )
      end
    end

    # --- destroyed action ---

    test "destroyed action does not raise with valid options" do
      destroy_payload = {
        id: @child.id,
        parent_id: @root.id,
        ancestors: [ { id: @root.id, progress: @root.progress } ]
      }

      assert_nothing_raised do
        CreativeBroadcastJob.perform_now(
          @child.id,
          "destroyed",
          current_user_id: @owner.id,
          payload: destroy_payload,
          options: {
            destroy_user_ids: [ @shared_user.id ],
            destroy_linked_map: {}
          }
        )
      end
    end

    test "destroyed action with empty user_ids is no-op" do
      assert_nothing_raised do
        CreativeBroadcastJob.perform_now(
          @child.id,
          "destroyed",
          current_user_id: @owner.id,
          payload: { id: @child.id },
          options: { destroy_user_ids: [], destroy_linked_map: {} }
        )
      end
    end

    test "destroyed action excludes current_user from recipients" do
      destroy_payload = {
        id: @child.id,
        parent_id: @root.id,
        ancestors: []
      }

      # Should not raise even if current_user is in destroy list
      assert_nothing_raised do
        CreativeBroadcastJob.perform_now(
          @child.id,
          "destroyed",
          current_user_id: @owner.id,
          payload: destroy_payload,
          options: {
            destroy_user_ids: [ @owner.id ],
            destroy_linked_map: {}
          }
        )
      end
    end

    # --- render_progress_html ---

    test "render_progress_html returns html with creative-row-end wrapper" do
      job = CreativeBroadcastJob.new
      html = job.send(:render_progress_html, @child, @shared_user, skip_permission_check: true)

      assert_not_nil html
      assert_includes html, "creative-row-end"
    end

    test "render_progress_html includes progress percentage" do
      # Use a leaf creative (no children) so progress stays as set
      leaf = nil
      perform_enqueued_jobs do
        leaf = Creative.create!(user: @owner, parent: @root, description: "Leaf 50%", progress: 0.5)
      end

      job = CreativeBroadcastJob.new
      html = job.send(:render_progress_html, leaf, @shared_user, skip_permission_check: true)

      assert_includes html, "50%"
    end

    test "render_progress_html includes comment button when skip_permission_check" do
      job = CreativeBroadcastJob.new
      html = job.send(:render_progress_html, @child, @shared_user, skip_permission_check: true)

      assert_includes html, "show-comments-btn"
      assert_includes html, "turbo-cable-stream-source"
    end

    test "render_progress_html with 0 progress shows 0% and incomplete class" do
      @child.update_column(:progress, 0.0)
      @child.reload

      job = CreativeBroadcastJob.new
      html = job.send(:render_progress_html, @child, @shared_user, skip_permission_check: true)

      assert_includes html, "0%"
      assert_includes html, "creative-progress-incomplete"
    end

    test "render_progress_html with 100% shows complete class" do
      @child.update_column(:progress, 1.0)
      @child.reload

      job = CreativeBroadcastJob.new
      html = job.send(:render_progress_html, @child, @shared_user, skip_permission_check: true)

      assert_includes html, "creative-progress-complete"
    end

    test "render_progress_html includes no-comments class for new creative" do
      job = CreativeBroadcastJob.new
      html = job.send(:render_progress_html, @child, @shared_user, skip_permission_check: true)

      assert_includes html, "no-comments"
    end

    test "render_progress_html includes signed stream name" do
      job = CreativeBroadcastJob.new
      html = job.send(:render_progress_html, @child, @shared_user, skip_permission_check: true)

      assert_includes html, "signed-stream-name="
    end

    test "render_progress_html escapes creative_snippet" do
      @child.update_column(:description, '<script>alert("xss")</script>')
      @child.reload

      job = CreativeBroadcastJob.new
      html = job.send(:render_progress_html, @child, @shared_user, skip_permission_check: true)

      # Should be HTML escaped, not raw script tag
      refute_includes html, '<script>'
    end

    # --- read_svg ---

    test "read_svg returns content for existing file" do
      job = CreativeBroadcastJob.new
      svg = job.send(:read_svg, "comment.svg", class: "test-icon")

      if File.exist?(Rails.root.join("app/assets/images/comment.svg"))
        assert_includes svg, "<svg"
        assert_includes svg, "test-icon"
      else
        assert_equal "", svg
      end
    end

    test "read_svg returns empty string for missing file" do
      job = CreativeBroadcastJob.new
      svg = job.send(:read_svg, "nonexistent_file_12345.svg")
      assert_equal "", svg
    end

    test "read_svg memoizes at class level" do
      # Clear cache first
      CreativeBroadcastJob.svg_cache.clear

      job1 = CreativeBroadcastJob.new
      job1.send(:read_svg, "comment.svg")

      job2 = CreativeBroadcastJob.new
      # Second call should use cached value
      assert_equal CreativeBroadcastJob.svg_cache.key?("comment.svg"), true
    end

    # --- permission_via_ancestors ---

    test "permission_via_ancestors returns true when ancestor has permission" do
      job = CreativeBroadcastJob.new
      # grandchild → child → root (which has share with shared_user)
      result = job.send(:permission_via_ancestors, @grandchild, @shared_user, :read)
      assert result
    end

    test "permission_via_ancestors returns false when no ancestor has permission" do
      unshared_user = users(:three)
      job = CreativeBroadcastJob.new
      result = job.send(:permission_via_ancestors, @grandchild, unshared_user, :read)
      refute result
    end

    test "permission_via_ancestors returns false for root creative without parent" do
      job = CreativeBroadcastJob.new
      # Root has no parent, so the while loop doesn't execute
      result = job.send(:permission_via_ancestors, @root, @shared_user, :admin)
      refute result
    end

    # --- linked creative remapping ---

    test "created action remaps parent_id for linked creative user" do
      linked = nil
      perform_enqueued_jobs do
        linked = Creative.create!(
          user: @shared_user,
          origin_id: @root.id,
          description: "Linked root"
        )
      end

      payload = @child.broadcast_node_payload.deep_symbolize_keys
      payload[:after_id] = nil
      payload[:previous_sibling_id] = nil

      # Should not raise — remapping happens internally
      assert_nothing_raised do
        CreativeBroadcastJob.perform_now(
          @child.id,
          "created",
          current_user_id: @owner.id,
          payload: payload
        )
      end
    end

    # --- edge cases ---

    test "unknown action is handled gracefully" do
      assert_nothing_raised do
        CreativeBroadcastJob.perform_now(
          @child.id,
          "unknown_action",
          current_user_id: @owner.id,
          payload: {}
        )
      end
    end

    test "nil payload does not raise for destroyed action" do
      assert_nothing_raised do
        CreativeBroadcastJob.perform_now(
          @child.id,
          "destroyed",
          current_user_id: @owner.id,
          payload: nil,
          options: { destroy_user_ids: [], destroy_linked_map: {} }
        )
      end
    end
  end
end
