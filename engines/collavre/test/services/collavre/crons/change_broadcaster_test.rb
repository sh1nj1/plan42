# frozen_string_literal: true

require "test_helper"

module Collavre
  module Crons
    class ChangeBroadcasterTest < ActiveSupport::TestCase
      test "broadcasts a cron change to the creative and its readable tree streams" do
        creative = creatives(:tshirt)
        broadcast = nil
        invalidations = []

        CreativeTreeInvalidationJob.stub(:perform_later, ->(ids) { invalidations << ids }) do
          TopicsChannel.stub(:broadcast_to, ->(*args) { broadcast = args }) do
            ChangeBroadcaster.call(creative)
          end
        end

        assert_equal [ creative, { action: "cron_changed" } ], broadcast
        assert_equal [ [ creative.id ] ], invalidations
      end

      test "does not fail the completed mutation when broadcasting fails" do
        creative = creatives(:tshirt)
        warning = nil
        invalidations = []

        Rails.logger.stub(:warn, ->(message) { warning = message }) do
          CreativeTreeInvalidationJob.stub(:perform_later, ->(ids) { invalidations << ids }) do
            TopicsChannel.stub(:broadcast_to, ->(*) { raise "cable unavailable" }) do
              ChangeBroadcaster.call(creative)
            end
          end
        end

        assert_match(/Broadcast failed for creative #{creative.id}: cable unavailable/, warning)
        assert_equal [ [ creative.id ] ], invalidations
      end

      test "broadcasts only the tree change when requested" do
        creative = creatives(:tshirt)
        invalidations = []

        TopicsChannel.stub(:broadcast_to, ->(*) { flunk "tree-only changes must not broadcast a topic event" }) do
          CreativeTreeInvalidationJob.stub(:perform_later, ->(ids) { invalidations << ids }) do
            ChangeBroadcaster.tree_only(creative)
          end
        end

        assert_equal [ [ creative.id ] ], invalidations
      end
    end
  end
end
