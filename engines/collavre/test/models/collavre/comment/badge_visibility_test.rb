# frozen_string_literal: true

require "test_helper"

module Collavre
  # The badge's show_zero flag answers "does this user have anything in this
  # conversation at all", so it has to stay per-user: a public comment counts
  # for everyone, a private one only for its author. These pin that contract so
  # the read behind it can be cheapened without changing what people see.
  class CommentBadgeVisibilityTest < ActiveSupport::TestCase
    setup do
      @owner = users(:one)
      @viewer = users(:two)
      @creative = Creative.create!(user: @owner, description: "Badge visibility", sequence: 941)
      CreativeShare.create!(creative: @creative, user: @viewer, shared_by: @owner, permission: :feedback)
    end

    test "no comments means every participant's badge stays hidden" do
      assert_equal({ @owner.id => false, @viewer.id => false }, show_zero_by_user_id)
    end

    test "a public comment reveals the badge for every participant" do
      Comment.create!(creative: @creative, user: @owner, content: "public")

      assert_equal({ @owner.id => true, @viewer.id => true }, show_zero_by_user_id)
    end

    test "a private comment reveals the badge only for its author" do
      Comment.create!(creative: @creative, user: @owner, content: "private", private: true)

      assert_equal({ @owner.id => true, @viewer.id => false }, show_zero_by_user_id)
    end

    test "a private comment reveals the badge for its approver" do
      Comment.create!(creative: @creative, user: @owner, approver: @viewer, content: "private", private: true)

      assert_equal({ @owner.id => true, @viewer.id => true }, show_zero_by_user_id)
    end

    test "a public comment outweighs another user's private one" do
      Comment.create!(creative: @creative, user: @owner, content: "private", private: true)
      Comment.create!(creative: @creative, user: @viewer, content: "public")

      assert_equal({ @owner.id => true, @viewer.id => true }, show_zero_by_user_id)
    end

    test "broadcast batches the presence lookup for every recipient" do
      calls = 0

      CommentPresenceStore.stub(:list, ->(_creative_id) { calls += 1; [] }) do
        show_zero_by_user_id
      end

      assert_equal 1, calls
    end

    private

    # Capture what broadcast_badges would render, keyed by the recipient, so the
    # assertions read as "what does each participant see".
    def show_zero_by_user_id
      captured = {}
      broadcast = lambda do |stream, **options|
        user = Array(stream).first
        next unless user.is_a?(Collavre::User)
        next unless options[:target] == "comment-badge-#{@creative.id}"

        captured[user.id] = options.dig(:locals, :show_zero)
      end

      Turbo::StreamsChannel.stub(:broadcast_replace_to, broadcast) do
        Comment.broadcast_badges(@creative)
      end

      captured
    end
  end
end
