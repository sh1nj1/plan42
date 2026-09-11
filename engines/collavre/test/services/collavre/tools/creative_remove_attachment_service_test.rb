# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class CreativeRemoveAttachmentServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        Current.user = @user
        @creative = Creative.create!(description: "<p>x</p>", user: @user)
        @creative.files.attach(io: StringIO.new("a"), filename: "a.txt", content_type: "text/plain")
        @attachment = @creative.files.first
        @signed_id = @attachment.blob.signed_id
      end

      teardown { Current.user = nil }

      test "removes the attachment by signed_id" do
        blob_id = @attachment.blob_id
        result = CreativeRemoveAttachmentService.new.call(
          creative_id: @creative.id,
          signed_id: @signed_id
        )
        assert result[:success]
        assert_equal 0, @creative.reload.files.count
        assert_not ActiveStorage::Blob.exists?(blob_id)
      end

      test "stores a direct agent attachment removal as a draft under review policy" do
        @creative.embed_attachment_blob!(@attachment.blob)
        task, agent = review_agent_turn(@creative)

        result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          CreativeRemoveAttachmentService.new.call(creative_id: @creative.id, signed_id: @signed_id)
        end

        assert result[:pending_review]
        assert_equal 1, @creative.reload.files.count
        draft = CreativeChangeSet.find(result[:change_set_id])
        assert_equal "draft", draft.status
        assert_equal 1, draft.creative_changes.sole.history_file_attachments.count

        applied = Creatives::ChangeSetApplyService.new(source: draft, user: @user, mode: :draft).call

        assert_equal :applied, applied.status
        assert_equal 0, @creative.reload.files.count
        assert ActiveStorage::Blob.exists?(@attachment.blob_id)
      end

      test "blocks an unembedded legacy removal that cannot be represented as a draft" do
        task, agent = review_agent_turn(@creative)

        result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          CreativeRemoveAttachmentService.new.call(creative_id: @creative.id, signed_id: @signed_id)
        end

        assert_match(/cannot be proposed/i, result[:error])
        assert_equal 1, @creative.reload.files.count
        assert_not CreativeChangeSet.where(task_id: task.id, status: "draft").exists?
      end

      test "localizes an unembedded legacy removal error" do
        task, agent = review_agent_turn(@creative)

        result = I18n.with_locale(:ko) do
          Current.set(user: agent, agent_turn: { user: @user, task: task }) do
            CreativeRemoveAttachmentService.new.call(creative_id: @creative.id, signed_id: @signed_id)
          end
        end

        assert_equal I18n.t("collavre.tools.creative_remove_attachment.errors.unembedded_review", locale: :ko),
                     result[:error]
      end

      test "strips the embedded node from the description and detaches" do
        # HTML is the source of truth: an attachment embedded in the description
        # must have its node removed, otherwise the next save reconciles the
        # blob back into creative.files (or leaves a dangling/broken asset).
        creative = Creative.create!(description: "<p>hi</p>", user: @user)
        blob = ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new("img"), filename: "p.png", content_type: "image/png"
        )
        creative.embed_attachment_blob!(blob)
        assert_includes creative.reload.description, blob.signed_id
        assert_equal 1, creative.files.count

        result = CreativeRemoveAttachmentService.new.call(
          creative_id: creative.id,
          signed_id: blob.signed_id
        )
        assert result[:success]
        creative.reload
        refute_includes creative.description, blob.signed_id
        refute_includes creative.description, "<img"
        assert_equal 0, creative.files.count
      end

      test "rejects when user lacks write permission" do
        other = users(:two)
        Current.user = other

        result = CreativeRemoveAttachmentService.new.call(
          creative_id: @creative.id,
          signed_id: @signed_id
        )
        assert_match(/permission/i, result[:error])
        assert_equal 1, @creative.reload.files.count
      end

      test "errors when signed_id does not belong to this creative" do
        other = Creative.create!(description: "<p>y</p>", user: @user)
        other.files.attach(io: StringIO.new("z"), filename: "z.txt", content_type: "text/plain")
        other_signed = other.files.first.blob.signed_id

        result = CreativeRemoveAttachmentService.new.call(
          creative_id: @creative.id,
          signed_id: other_signed
        )
        assert_match(/not found/i, result[:error])
        assert_equal 1, @creative.reload.files.count
      end

      private

      def review_agent_turn(creative)
        creative.update_column(:data, creative.data.merge("ai_write_policy" => "review"))
        agent = users(:ai_bot)
        share = CreativeShare.find_or_initialize_by(creative: creative, user: agent)
        share.update!(shared_by: @user, permission: :write)
        topic = Topic.create!(creative: creative, user: @user, name: "Review removal")
        task = Task.create!(agent: agent, creative: creative, topic_id: topic.id, name: "Review", status: "running")
        [ task, agent ]
      end
    end
  end
end
