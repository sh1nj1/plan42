# frozen_string_literal: true

require "test_helper"

class SolidCableInlineBroadcastTest < ActiveSupport::TestCase
  class InlineAdapter
    include SolidCableInlineBroadcast

    private

    def trim_batches(count)
      count
    end
  end

  test "persists a broadcast on the calling thread before trimming" do
    events = []
    caller = Thread.current
    persist = ->(channel, payload) { events << [ Thread.current, channel, payload ] }
    trim = -> { events << :trimmed }

    SolidCable.stub(:autotrim?, true) do
      SolidCable::Message.stub(:broadcast, persist) do
        SolidCable::TrimJob.stub(:perform_now, trim) do
          InlineAdapter.new.broadcast("stream", "update")
        end
      end
    end

    assert_equal [ [ caller, "stream", "update" ], :trimmed ], events
  end

  test "propagates a failed write to the broadcasting caller" do
    persist = ->(*) { raise ActiveRecord::ConnectionNotEstablished }
    SolidCable::Message.stub(:broadcast, persist) do
      assert_raises(ActiveRecord::ConnectionNotEstablished) do
        InlineAdapter.new.broadcast("stream", "update")
      end
    end
  end
end
