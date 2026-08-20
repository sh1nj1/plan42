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

      def post(content, action: nil, private_flag: false, approver: nil)
        Comment.create!(creative: @creative, topic: @source, user: @user, content: content,
                        action: action, private: private_flag, approver: approver,
                        skip_default_user: true, skip_dispatch: true)
      end

      def share!(user, permission)
        Collavre::CreativeShare.create!(creative: @creative, user: user, permission: permission, shared_by: @user)
      end

      # The branch copies content but not `action`, so a copied approval prompt
      # stops matching Comment.without_approval_action and lands in the agent
      # history queries the column exists to keep it out of.
      test "an approval prompt cannot be branched" do
        prompt = post("Approve the deploy?", action: "approve")

        error = assert_raises(::Collavre::TopicBranchService::BranchError) do
          TopicBranchService.new.call(source_topic_id: @source.id, comment_ids: prompt.id)
        end

        assert_equal I18n.t("collavre.comments.branch.approval_action_not_branchable"), error.message
        assert_equal 0, @creative.topics.where(source_topic_id: @source.id).count
      end

      test "an approval prompt mixed into an otherwise valid selection fails the whole branch" do
        prompt = post("Approve the deploy?", action: "approve")
        ids = [ @comments.first.id, prompt.id ]

        assert_raises(::Collavre::TopicBranchService::BranchError) do
          TopicBranchService.new.call(source_topic_id: @source.id, comment_ids: ids.join(","))
        end

        assert_equal 0, @creative.topics.where(source_topic_id: @source.id).count
      end

      test "an ordinary message changed into an approval prompt after preflight is not copied" do
        comment = @comments.first
        constructor = ::Collavre::TopicBranchService.method(:new)
        mutate_after_preflight = lambda do |**arguments|
          comment.update!(action: "approve")
          constructor.call(**arguments)
        end

        assert_raises(::Collavre::TopicBranchService::BranchError) do
          ::Collavre::TopicBranchService.stub(:new, mutate_after_preflight) do
            TopicBranchService.new.call(source_topic_id: @source.id, comment_ids: comment.id)
          end
        end

        assert_equal 0, @creative.topics.where(source_topic_id: @source.id).count
      end

      # The refusal names the id, so running it over the whole topic answered
      # "is comment N an approval prompt?" for a comment the caller cannot read
      # — a distinct error where every other hidden id gets the generic
      # not-found. Feedback is granted here so the probe reaches the furthest
      # point it can: the check ran before the wrapped service's permission
      # gate, so read alone was enough to ask.
      test "a hidden approval prompt is not distinguishable from any other unreadable id" do
        hidden = post("Approve the deploy?", action: "approve", private_flag: true)
        share!(@stranger, :feedback)
        Collavre::Current.user = @stranger

        hidden_error = assert_raises(::Collavre::TopicBranchService::BranchError) do
          TopicBranchService.new.call(source_topic_id: @source.id, comment_ids: hidden.id)
        end
        absent_error = assert_raises(::Collavre::TopicBranchService::BranchError) do
          TopicBranchService.new.call(source_topic_id: @source.id, comment_ids: 999_999)
        end

        assert_equal absent_error.message, hidden_error.message
        assert_equal 0, @creative.topics.where(source_topic_id: @source.id).count
      end

      test "a visible approval prompt is still refused" do
        prompt = post("Approve the deploy?", action: "approve")

        error = assert_raises(::Collavre::TopicBranchService::BranchError) do
          TopicBranchService.new.call(source_topic_id: @source.id, comment_ids: prompt.id)
        end

        assert_equal I18n.t("collavre.comments.branch.approval_action_not_branchable"), error.message
      end

      # visible_to reads a private comment for its author and its approver, so
      # copying `private` without `approver_id` narrows who can see the copy.
      # The caller selecting the message can be the approver rather than the
      # author, and would get a branch whose copied_count counts a message the
      # branch will never show them.
      test "branching a private message carries its approver onto the copy" do
        share!(@stranger, :feedback)
        secret = post("between us", private_flag: true, approver: @stranger)
        Collavre::Current.user = @stranger

        result = TopicBranchService.new.call(source_topic_id: @source.id, comment_ids: secret.id)
        copies = Topic.find(result[:id]).comments

        assert_equal 1, result[:copied_count]
        assert_equal 1, copies.visible_to(@stranger).count
        assert_equal @stranger.id, copies.sole.approver_id
      end

      test "the copy of an ordinary message stays outside the approval surface" do
        result = TopicBranchService.new.call(source_topic_id: @source.id, comment_ids: @comments.first.id)

        assert_equal 1, Topic.find(result[:id]).comments.without_approval_action.count
      end

      test "copies an image-only message with its attachments" do
        original = Comment.new(creative: @creative, topic: @source, user: @user, content: "",
                               skip_default_user: true, skip_dispatch: true)
        original.images.attach(
          io: StringIO.new("image bytes"), filename: "diagram.png", content_type: "image/png"
        )
        original.save!

        result = TopicBranchService.new.call(source_topic_id: @source.id, comment_ids: original.id)
        copy = Topic.find(result[:id]).comments.sole

        assert_equal "", copy.content
        assert_equal [ original.images.sole.blob_id ], copy.images.map(&:blob_id)
        assert_equal "diagram.png", copy.images.sole.filename.to_s
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

      test "an inbox branch cannot take the reserved System name" do
        inbox = Collavre::Creative.create!(description: "Inbox", user: @user, data: { "kind" => "inbox" })
        source = inbox.topics.create!(name: "Conversation", user: @user)
        comment = Comment.create!(creative: inbox, topic: source, user: @user, content: "carry me",
                                  skip_default_user: true, skip_dispatch: true)
        assert_nil inbox.topics.find_by(name: Collavre::Creative::SYSTEM_TOPIC_NAME)

        error = assert_raises(::Collavre::TopicBranchService::BranchError) do
          TopicBranchService.new.call(source_topic_id: source.id, comment_ids: comment.id,
                                      name: Collavre::Creative::SYSTEM_TOPIC_NAME)
        end

        assert_includes error.message, "reserved"
        assert_nil inbox.topics.find_by(name: Collavre::Creative::SYSTEM_TOPIC_NAME)
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

      test "reauthorizes a source moved to an inaccessible creative after locking it" do
        restricted = Collavre::Creative.create!(description: "Restricted", user: @stranger)
        lock_after_move = lambda do
          @source.update_column(:creative_id, restricted.id)
          @source.reload
        end

        Collavre::Topic.stub(:find, @source) do
          @source.stub(:lock!, lock_after_move) do
            assert_raises(::Collavre::TopicBranchService::BranchError) do
              TopicBranchService.new.call(source_topic_id: @source.id, comment_ids: @comments.first.id)
            end
          end
        end

        assert_equal 0, @creative.topics.where(source_topic_id: @source.id).count
        assert_equal 0, restricted.topics.where(source_topic_id: @source.id).count
      end

      test "does not reveal approval state after the source moves to an inaccessible creative" do
        prompt = post("Approve the deploy?", action: "approve")
        restricted = Collavre::Creative.create!(description: "Restricted", user: @stranger)
        parse = IdList.method(:parse)
        move_after_authorization = lambda do |value|
          @source.comments.update_all(creative_id: restricted.id)
          @source.update_column(:creative_id, restricted.id)
          parse.call(value)
        end

        error = assert_raises(::Collavre::TopicBranchService::BranchError) do
          IdList.stub(:parse, move_after_authorization) do
            TopicBranchService.new.call(source_topic_id: @source.id, comment_ids: prompt.id)
          end
        end

        assert_equal I18n.t("collavre.comments.branch.not_authorized"), error.message
        assert_not_includes error.message, "approval"
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
