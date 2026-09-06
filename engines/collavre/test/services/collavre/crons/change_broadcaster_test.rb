# frozen_string_literal: true

require "test_helper"

module Collavre
  module Crons
    class ChangeBroadcasterTest < ActiveSupport::TestCase
      test "broadcasts a cron change to the creative" do
        creative = creatives(:tshirt)
        broadcast = nil

        TopicsChannel.stub(:broadcast_to, ->(*args) { broadcast = args }) do
          ChangeBroadcaster.call(creative)
        end

        assert_equal [ creative, { action: "cron_changed" } ], broadcast
      end

      test "does not fail the completed mutation when broadcasting fails" do
        creative = creatives(:tshirt)
        warning = nil

        Rails.logger.stub(:warn, ->(message) { warning = message }) do
          TopicsChannel.stub(:broadcast_to, ->(*) { raise "cable unavailable" }) do
            ChangeBroadcaster.call(creative)
          end
        end

        assert_match(/Broadcast failed for creative #{creative.id}: cable unavailable/, warning)
      end
    end
  end
end
