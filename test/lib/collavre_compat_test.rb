# frozen_string_literal: true

require "test_helper"

class CollavreCompatTest < ActiveSupport::TestCase
  # Older Collavre gem versions don't accept boot_safe:; the helper must
  # drop it instead of raising ArgumentError so USE_COLLAVRE_GEM=true
  # deployments boot.

  class OldReceiver
    def self.fetch(key, default: nil)
      { key: key, default: default }
    end
  end

  class NewReceiver
    def self.fetch(key, default: nil, boot_safe: false)
      { key: key, default: default, boot_safe: boot_safe }
    end
  end

  class KwargRestReceiver
    def self.fetch(key, **kwargs)
      { key: key, kwargs: kwargs }
    end
  end

  test "drops unsupported keyword on older signature" do
    result = CollavreCompat.call(OldReceiver, :fetch, :foo, default: "d", boot_safe: true)
    assert_equal({ key: :foo, default: "d" }, result)
  end

  test "forwards supported keyword on newer signature" do
    result = CollavreCompat.call(NewReceiver, :fetch, :foo, default: "d", boot_safe: true)
    assert_equal({ key: :foo, default: "d", boot_safe: true }, result)
  end

  test "passes everything through when receiver accepts a kwarg splat" do
    result = CollavreCompat.call(KwargRestReceiver, :fetch, :foo, default: "d", boot_safe: true, extra: 1)
    assert_equal({ key: :foo, kwargs: { default: "d", boot_safe: true, extra: 1 } }, result)
  end

  test "forwards positional arguments unchanged" do
    receiver = Class.new do
      def self.greet(a, b, salutation: "Hi")
        "#{salutation} #{a} #{b}"
      end
    end
    assert_equal "Hi alice bob",
                 CollavreCompat.call(receiver, :greet, "alice", "bob", salutation: "Hi", legacy: true)
  end
end
