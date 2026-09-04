# frozen_string_literal: true

require "test_helper"

module Collavre
  class CreativeChangeSetsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @user = users(:one)
      @creative = creatives(:tshirt)
      @user.update!(email_verified_at: Time.current)
      post session_path, params: { email: @user.email, password: "password" }
      @before = Creatives::History.snapshot(@creative)
      Creatives::History.track(actor: @user, origin: :tool, anchor: @creative, anchor_source: :explicit) do
        @creative.update!(progress: 0.75)
        @change_set = CreativeChangeSet.order(:id).last
      end
    end

    test "revert creates an append-only reverse change set" do
      assert_difference("CreativeChangeSet.count", 1) do
        post creative_apply_change_set_path(@creative, @change_set), params: { mode: "revert" }, as: :json
      end

      assert_response :success
      assert_equal "applied", response.parsed_body["status"]
      assert_equal @before, Creatives::History.snapshot(@creative.reload)
      assert_equal "reverted", @change_set.reload.status
    end

    test "revert returns conflict details after a later edit" do
      Creatives::History.track(actor: @user, origin: :editor, anchor: @creative, anchor_source: :view_root) do
        @creative.update!(progress: 0.9)
      end

      post creative_apply_change_set_path(@creative, @change_set), params: { mode: "revert" }, as: :json

      assert_response :conflict
      assert_equal "conflict", response.parsed_body["status"]
      assert_equal @creative.id, response.parsed_body.dig("conflicts", 0, "creative_id")
    end

    test "revert ignores invalid conflict resolutions" do
      @creative.update!(progress: 0.9)

      post creative_apply_change_set_path(@creative, @change_set),
           params: { mode: "revert", resolutions: { @creative.id => "invalid", bad: "force" } }, as: :json

      assert_response :conflict
      assert_equal "conflict", response.parsed_body["status"]
    end

    test "read-only users cannot force a revert" do
      other = users(:two)
      other.update!(email_verified_at: Time.current)
      CreativeShare.create!(creative: @creative, user: other, shared_by: @user, permission: :read)
      delete session_path
      post session_path, params: { email: other.email, password: "password" }

      post creative_apply_change_set_path(@creative, @change_set),
           params: { mode: "revert", resolutions: { @creative.id => "force" } }, as: :json

      assert_response :unprocessable_entity
      assert_equal "skipped", response.parsed_body["status"]
      assert_equal [ @creative.id ], response.parsed_body["skipped"]
    end

    test "a partial revert stays successful and retryable" do
      foreign = Creative.create!(description: "Foreign after", user: users(:two))
      perform_enqueued_jobs do
        CreativeShare.create!(creative: foreign, user: @user, shared_by: users(:two), permission: :read)
      end
      @change_set.creative_changes.create!(
        creative: foreign,
        operation: "update",
        before: Creatives::History.snapshot(foreign).merge("description" => "Foreign before"),
        after: Creatives::History.snapshot(foreign),
        position: 1
      )

      post creative_apply_change_set_path(@creative, @change_set), params: { mode: "revert" }, as: :json

      assert_response :success
      assert_equal "partial", response.parsed_body["status"]
      assert_equal [ foreign.id ], response.parsed_body["skipped"]
      assert_equal "applied", @change_set.reload.status
    end

    test "restore makes the selected snapshot current without a conflict" do
      @creative.update!(progress: 0.9)

      post creative_apply_change_set_path(@creative, @change_set), params: { mode: "restore" }, as: :json

      assert_response :success
      assert_equal 0.75, @creative.reload.progress
      assert_equal "applied", @change_set.reload.status
    end

    test "revert resolves a change set through a linked Creative scope" do
      linked = nil
      creation = nil
      Creatives::History.track(actor: @user, origin: :tool, anchor: @creative) do
        linked = Creative.create!(user: @user, origin: @creative)
        creation = Current.change_set
      end

      post creative_apply_change_set_path(linked, creation), params: { mode: "revert" }, as: :json

      assert_response :success
      assert linked.reload.archived?
    end

    test "rejects a foreign private linked placement even when its origin is readable" do
      foreign_parent = Creative.create!(description: "Private", user: users(:two))
      linked = Creative.create!(user: users(:two), parent: foreign_parent, origin: @creative)

      post creative_apply_change_set_path(linked, @change_set), params: { mode: "revert" }, as: :json

      assert_response :forbidden
    end

    test "approves a draft create and remaps its temporary id" do
      draft = build_review_draft([
        { "action" => "create", "parent_id" => @creative.id, "description" => "Proposed child" }
      ])
      temporary_id = draft.creative_changes.find_by!(operation: "create").creative_id

      assert_difference("Creative.count", 1) do
        post creative_apply_change_set_path(@creative, draft), params: { mode: "approve" }, as: :json
      end

      assert_response :success
      assert_equal "applied", response.parsed_body["status"]
      assert_equal "applied", draft.reload.status
      assert draft.applied_at
      refute draft.creative_changes.exists?(creative_id: temporary_id)
      created = @creative.children.where("description LIKE ?", "%Proposed child%").sole
      assert draft.creative_changes.exists?(creative_id: created.id)
    end

    test "approves a nested draft import with remapped parent ids" do
      draft = build_review_import("# Project\n## Child")

      post creative_apply_change_set_path(@creative, draft), params: { mode: "approve" }, as: :json

      assert_response :success
      project = @creative.children.where("description LIKE ?", "%Project%").sole
      assert project.children.where("description LIKE ?", "%Child%").exists?
      assert_equal "applied", draft.reload.status
      assert draft.creative_changes.pluck(:creative_id).all?(&:positive?)
    end

    test "rejects a draft without applying it" do
      draft = build_review_draft([
        { "action" => "update", "id" => @creative.id, "description" => "Do not apply" }
      ])

      post creative_apply_change_set_path(@creative, draft), params: { mode: "reject" }, as: :json

      assert_response :success
      assert_equal "rejected", response.parsed_body["status"]
      assert_equal "rejected", draft.reload.status
      refute_includes @creative.reload.description, "Do not apply"
    end

    test "reports a conflict when a draft target changed after capture" do
      draft = build_review_draft([
        { "action" => "update", "id" => @creative.id, "description" => "Proposed" }
      ])
      @creative.update!(description: "Later human edit")

      post creative_apply_change_set_path(@creative, draft), params: { mode: "approve" }, as: :json

      assert_response :conflict
      assert_equal "draft", draft.reload.status
      assert_includes @creative.reload.description, "Later human edit"
    end

    test "applies nonconflicting draft changes when a conflict is skipped" do
      child = Creative.create!(description: "Child", user: @user, parent: @creative)
      draft = build_review_draft([
        { "action" => "update", "id" => @creative.id, "description" => "Proposed parent" },
        { "action" => "update", "id" => child.id, "description" => "Proposed child" }
      ])
      @creative.update!(description: "Later human edit")

      post creative_apply_change_set_path(@creative, draft),
           params: { mode: "approve", resolutions: { @creative.id => "skip" } }, as: :json

      assert_response :success
      assert_equal "partial", response.parsed_body["status"]
      assert_equal [ @creative.id ], response.parsed_body["skipped"]
      assert_includes @creative.reload.description, "Later human edit"
      assert_includes child.reload.description, "Proposed child"
      refute draft.creative_changes.exists?(creative_id: @creative.id)
      assert_equal "applied", draft.reload.status
    end

    test "does not treat a requested skip as authority over an unwritable draft target" do
      draft = build_review_draft([
        { "action" => "update", "id" => @creative.id, "description" => "Authorized proposal" }
      ])
      foreign = append_unwritable_draft_change(draft)

      post creative_apply_change_set_path(@creative, draft),
           params: { mode: "approve", resolutions: { foreign.id => "skip" } }, as: :json

      assert_response :unprocessable_entity
      assert_equal "skipped", response.parsed_body["status"]
      assert_equal "draft", draft.reload.status
      assert draft.creative_changes.exists?(creative_id: foreign.id)
      refute_includes @creative.reload.description, "Authorized proposal"
    end

    test "rejects only when the reviewer can write every draft target" do
      draft = build_review_draft([
        { "action" => "update", "id" => @creative.id, "description" => "Authorized proposal" }
      ])
      foreign = append_unwritable_draft_change(draft)

      post creative_apply_change_set_path(@creative, draft), params: { mode: "reject" }, as: :json

      assert_response :unprocessable_entity
      assert_equal "skipped", response.parsed_body["status"]
      assert_equal "draft", draft.reload.status
      assert draft.creative_changes.exists?(creative_id: foreign.id)
    end

    test "rejects a draft when every actual conflict is skipped" do
      draft = build_review_draft([
        { "action" => "update", "id" => @creative.id, "description" => "Proposed" }
      ])
      @creative.update!(description: "Later human edit")

      post creative_apply_change_set_path(@creative, draft),
           params: { mode: "approve", resolutions: { @creative.id => "skip" } }, as: :json

      assert_response :success
      assert_equal "rejected", response.parsed_body["status"]
      assert_equal "rejected", draft.reload.status
      assert draft.creative_changes.exists?(creative_id: @creative.id)
      assert_includes @creative.reload.description, "Later human edit"
    end

    test "finalizes a draft with skipped conflicts and already-current proposals" do
      child = Creative.create!(description: "Child", user: @user, parent: @creative)
      draft = build_review_draft([
        { "action" => "update", "id" => @creative.id, "description" => "Proposed parent" },
        { "action" => "update", "id" => child.id, "description" => "Proposed child" }
      ])
      @creative.update!(description: "Later human edit")
      child_change = draft.creative_changes.find_by!(creative_id: child.id)
      Creatives::SnapshotAssignment.call(child, child_change.after)
      child.save!

      post creative_apply_change_set_path(@creative, draft),
           params: { mode: "approve", resolutions: { @creative.id => "skip" } }, as: :json

      assert_response :success
      assert_equal "partial", response.parsed_body["status"]
      assert_equal "applied", draft.reload.status
      refute draft.creative_changes.exists?(creative_id: @creative.id)
      assert draft.creative_changes.exists?(creative_id: child.id)
      assert_includes child.reload.description, "Proposed child"
    end

    test "does not approve a draft without an explicit mode" do
      draft = build_review_draft([
        { "action" => "update", "id" => @creative.id, "description" => "Proposed" }
      ])

      post creative_apply_change_set_path(@creative, draft), as: :json

      assert_response :unprocessable_entity
      assert_equal "not_revertible", response.parsed_body["status"]
      assert_equal "draft", draft.reload.status
      refute_includes @creative.reload.description, "Proposed"
    end

    test "finalizes a draft when its proposed state is already current" do
      snapshot = Creatives::History.snapshot(@creative)
      draft = CreativeChangeSet.create!(
        anchor_creative: @creative, anchor_source: "agent_topic", user: users(:ai_bot),
        actor_kind: "agent", origin: "tool", status: "draft"
      )
      draft.creative_changes.create!(
        creative: @creative, operation: "update",
        before: snapshot.merge("description" => "Earlier"), after: snapshot, position: 0
      )

      post creative_apply_change_set_path(@creative, draft), params: { mode: "approve" }, as: :json

      assert_response :success
      assert_equal "applied", response.parsed_body["status"]
      assert_equal "applied", draft.reload.status
      assert draft.applied_at
    end

    test "does not let a read-only viewer approve or reject a draft" do
      draft = build_review_draft([
        { "action" => "update", "id" => @creative.id, "description" => "Proposed" }
      ])
      viewer = users(:two)
      viewer.update!(email_verified_at: Time.current)
      share = CreativeShare.find_or_initialize_by(creative: @creative, user: viewer)
      share.update!(shared_by: @user, permission: :read)
      delete session_path
      post session_path, params: { email: viewer.email, password: "password" }

      post creative_apply_change_set_path(@creative, draft), params: { mode: "approve" }, as: :json
      assert_response :unprocessable_entity
      assert_equal "draft", draft.reload.status

      post creative_apply_change_set_path(@creative, draft), params: { mode: "reject" }, as: :json
      assert_response :unprocessable_entity
      assert_equal "draft", draft.reload.status
      refute_includes @creative.reload.description, "Proposed"
    end

    private

    def build_review_draft(operations)
      @creative.update!(data: @creative.data.merge("ai_write_policy" => "review"))
      agent, task = review_agent_and_task
      result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
        Tools::CreativeBatchService.new.call(operations: operations)
      end
      CreativeChangeSet.find(result.fetch(:change_set_id))
    end

    def build_review_import(markdown)
      @creative.update!(data: @creative.data.merge("ai_write_policy" => "review"))
      agent, task = review_agent_and_task
      result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
        Tools::CreativeImportService.new.call(markdown: markdown, parent_id: @creative.id)
      end
      CreativeChangeSet.find(result.fetch(:change_set_id))
    end

    def review_agent_and_task
      agent = users(:ai_bot)
      CreativeShare.find_or_create_by!(creative: @creative, user: agent) do |share|
        share.shared_by = @user
        share.permission = :write
      end
      topic = Topic.create!(creative: @creative, user: @user, name: "Draft #{SecureRandom.hex(3)}")
      task = Task.create!(agent: agent, creative: @creative, topic_id: topic.id, name: "Draft", status: "running")
      [ agent, task ]
    end

    def append_unwritable_draft_change(draft)
      foreign = Creative.create!(description: "Foreign", user: users(:two))
      perform_enqueued_jobs do
        CreativeShare.create!(creative: foreign, user: @user, shared_by: users(:two), permission: :read)
      end
      snapshot = Creatives::History.snapshot(foreign)
      draft.creative_changes.create!(
        creative: foreign, operation: "update", before: snapshot,
        after: snapshot.merge("description" => "Unauthorized proposal"), position: 1
      )
      foreign
    end
  end
end
