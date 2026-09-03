# frozen_string_literal: true

require "test_helper"

module Collavre
  class CreativeHistoryNoticeJobTest < ActiveJob::TestCase
    test "broadcasts a localized undo notice for a visible agent change" do
      user = users(:one)
      agent = users(:ai_bot)
      creative = Creative.create!(description: "Before", user: user)
      before = Creatives::History.snapshot(creative)
      Current.set(user: agent) { creative.update!(description: "After") }
      change_set = CreativeChangeSet.sole
      broadcasts = []

      Turbo::StreamsChannel.stub(:broadcast_append_to, ->(*stream, **options) { broadcasts << [ stream, options ] }) do
        CreativeHistoryNoticeJob.perform_now(change_set.id, user.id)
      end

      stream, options = broadcasts.sole
      assert_equal [ [ user, :creative_tree ] ], stream
      assert_equal "creative-history-toast-container", options[:target]
      assert_equal "collavre/creative_change_sets/undo_toast", options[:partial]
      assert_equal "/creatives/#{creative.id}/history/#{change_set.id}/apply", options.dig(:locals, :apply_url)
      assert_equal 1, options.dig(:locals, :change_count)
      assert_equal before, change_set.creative_changes.sole.before
    end

    test "does not broadcast a human change" do
      user = users(:one)
      creative = Creative.create!(description: "Before", user: user)
      Current.set(user: user) { creative.update!(description: "After") }

      Turbo::StreamsChannel.stub(:broadcast_append_to, ->(*) { flunk "human changes must not produce AI undo notices" }) do
        CreativeHistoryNoticeJob.perform_now(CreativeChangeSet.sole.id, user.id)
      end
      assert true
    end

    test "does not offer undo to a read-only viewer" do
      owner = users(:one)
      reader = users(:two)
      agent = users(:ai_bot)
      creative = Creative.create!(description: "Before", user: owner)
      CreativeShare.create!(creative: creative, user: reader, shared_by: owner, permission: :read)
      Current.set(user: agent) { creative.update!(description: "After") }

      Turbo::StreamsChannel.stub(:broadcast_append_to, ->(*) { flunk "read-only viewers must not receive undo" }) do
        CreativeHistoryNoticeJob.perform_now(CreativeChangeSet.sole.id, reader.id)
      end
      assert true
    end

    test "renders an actionable undo toast" do
      user = users(:one)
      agent = users(:ai_bot)
      creative = Creative.create!(description: "Before", user: user)
      Current.set(user: agent) { creative.update!(description: "After") }
      change_set = CreativeChangeSet.sole
      payloads = []

      ActionCable.server.stub(:broadcast, ->(_stream, payload) { payloads << payload }) do
        CreativeHistoryNoticeJob.perform_now(change_set.id, user.id)
      end

      payload = payloads.sole
      assert_includes payload, %(id="creative-history-undo-#{change_set.id}")
      assert_includes payload, %(/creatives/#{creative.id}/history/#{change_set.id}/apply)
      assert_includes payload, "AI updated 1 creative."
    end
  end
end
