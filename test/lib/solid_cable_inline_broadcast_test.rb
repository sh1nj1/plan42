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

  test "installs the fallback only for an adapter with batching and no inline option" do
    adapter_class = Class.new do
      private

      def broadcaster; end
    end

    trimming = Module.new
    stub_const(SolidCable, :Trimming, trimming, exists: SolidCable.const_defined?(:Trimming, false)) do
      SolidCableInlineBroadcast.install!(adapter_class)

      assert_includes adapter_class.ancestors, SolidCableInlineBroadcast
      assert_includes adapter_class.ancestors, trimming
    end
  end

  test "leaves an adapter without batching unchanged" do
    adapter_class = Class.new

    SolidCableInlineBroadcast.install!(adapter_class)

    refute_includes adapter_class.ancestors, SolidCableInlineBroadcast
  end

  test "defers to the native inline option when available" do
    adapter_class = Class.new do
      private

      def broadcaster; end
    end

    SolidCable.stub(:respond_to?, true) do
      SolidCableInlineBroadcast.install!(adapter_class)
    end

    refute_includes adapter_class.ancestors, SolidCableInlineBroadcast
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
