# frozen_string_literal: true

require "test_helper"

class SolidCableInlineBroadcastTest < ActiveSupport::TestCase
  class InlineAdapter < ActionCable::SubscriptionAdapter::SolidCable
    prepend SolidCableInlineBroadcast

    private

    def trim_batches(count)
      count
    end
  end

  setup do
    config = ActionCable::Server::Configuration.new
    config.cable = { channel_prefix: "collavre" }
    @adapter = InlineAdapter.new(ActionCable::Server::Base.new(config: config))
  end

  test "persists a broadcast on the calling thread before trimming" do
    events = []
    caller = Thread.current
    persist = ->(channel, payload) { events << [ Thread.current, channel, payload ] }
    trim = -> { events << :trimmed }

    SolidCable.stub(:autotrim?, true) do
      SolidCable::Message.stub(:broadcast, persist) do
        SolidCable::TrimJob.stub(:perform_now, trim) do
          @adapter.broadcast("stream", "update")
        end
      end
    end

    assert_equal [ [ caller, "collavre:stream", "update" ], :trimmed ], events
  end

  test "propagates a failed write to the broadcasting caller" do
    persist = ->(*) { raise ActiveRecord::ConnectionNotEstablished }
    SolidCable::Message.stub(:broadcast, persist) do
      assert_raises(ActiveRecord::ConnectionNotEstablished) do
        @adapter.broadcast("stream", "update")
      end
    end
  end
end
