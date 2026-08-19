# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class TopicBranchServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @stranger = users(:two)
        @creative = Collavre::Creative.create!(description: "Branch Host", user: @user)
        @source = @creative.topics.create!(name: "Long thread", user: @user)
        @comments = 3.times.map { |i| post("m#{i}") }
        Collavre::Current.user = @user
      end

      teardown { Collavre::Current.user = nil }

      def post(content)
        Comment.create!(creative: @creative, topic: @source, user: @user, content: content,
                        skip_default_user: true, skip_dispatch: true)
      end

      test "copies the selected messages into a new topic and leaves the originals" do
        ids = @comments.first(2).map(&:id)
        result = TopicBranchService.new.call(source_topic_id: @source.id, comment_ids: ids.join(","),
                                             name: "Focused")

        assert_equal "Focused", result[:name]
        assert_equal @source.id, result[:source_topic_id]
        assert_equal 2, result[:copied_count]
        assert_equal 2, Topic.find(result[:id]).comments.count
        assert_equal 3, @source.comments.count
      end

      test "records the source so the branch can be traced back" do
        result = TopicBranchService.new.call(source_topic_id: @source.id, comment_ids: @comments.first.id)

        assert_equal @source.id, Topic.find(result[:id]).source_topic_id
      end

      test "defaults to a generated branch name" do
        result = TopicBranchService.new.call(source_topic_id: @source.id, comment_ids: @comments.first.id)

        assert_includes result[:name], I18n.t("collavre.topics.branch_prefix")
      end

      test "requires at least one message id" do
        assert_raises(ArgumentError) { TopicBranchService.new.call(source_topic_id: @source.id, comment_ids: "") }
      end

      # The wrapped service trims an oversized selection and reports success for
      # the shortened list; through a tool that would silently lose messages.
      test "an oversized selection is an error rather than a silent trim" do
        ids = (1..::Collavre::TopicBranchService::MAX_BRANCH_COMMENTS + 1).to_a
        error = assert_raises(ArgumentError) do
          TopicBranchService.new.call(source_topic_id: @source.id, comment_ids: ids.join(","))
        end

        assert_includes error.message, "at most #{::Collavre::TopicBranchService::MAX_BRANCH_COMMENTS}"
      end

      test "a message id from another topic is refused" do
        other = @creative.topics.create!(name: "Elsewhere", user: @user)
        stray = Comment.create!(creative: @creative, topic: other, user: @user, content: "stray",
                                skip_default_user: true, skip_dispatch: true)

        assert_raises(::Collavre::TopicBranchService::BranchError) do
          TopicBranchService.new.call(source_topic_id: @source.id, comment_ids: stray.id)
        end
      end

      test "requires read access to the source topic" do
        Collavre::Current.user = @stranger

        assert_raises(Collavre::Tools::PermissionDeniedError) do
          TopicBranchService.new.call(source_topic_id: @source.id, comment_ids: @comments.first.id)
        end
      end

      test "read alone is not enough to branch — the copy needs feedback" do
        Collavre::CreativeShare.create!(creative: @creative, user: @stranger, permission: :read, shared_by: @user)
        Collavre::Current.user = @stranger

        assert_raises(::Collavre::TopicBranchService::BranchError) do
          TopicBranchService.new.call(source_topic_id: @source.id, comment_ids: @comments.first.id)
        end
      end

      test "requires a current user" do
        Collavre::Current.user = nil

        assert_raises(RuntimeError) do
          TopicBranchService.new.call(source_topic_id: @source.id, comment_ids: @comments.first.id)
        end
      end

      test "the branch is readable through topic_messages" do
        result = TopicBranchService.new.call(source_topic_id: @source.id,
                                             comment_ids: @comments.map(&:id).join(","))
        payload = TopicMessagesService.new.call(topic_ids: result[:id], format: "json")

        assert_equal %w[m0 m1 m2], payload[:topics].first[:messages].map { |m| m[:content] }
      end
    end
  end
end
