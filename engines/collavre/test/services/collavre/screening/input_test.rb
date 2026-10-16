# frozen_string_literal: true

require "test_helper"

module Collavre
  module Screening
    class InputTest < ActiveSupport::TestCase
      test "labels sources and packs them into one input" do
        chunks = Input.chunks([ { source: "trigger", text: "hello" }, { source: "history", text: "world" },
                                { source: "empty", text: "  " } ])
        assert_equal [ "[source: trigger]\nhello\n\n[source: history]\nworld" ], chunks
      end

      test "splits text longer than the input limit" do
        chunks = Input.chunks([ { source: "doc", text: "x" * (Input::MAX_CHARS + 5) } ])
        assert_equal 2, chunks.size
        assert chunks.all? { |chunk| chunk.start_with?("[source: doc]\n") }
        assert chunks.all? { |chunk| chunk.length <= Input::MAX_CHARS }
      end

      test "nothing to screen yields no input" do
        assert_empty Input.chunks([ { source: "trigger", text: nil } ])
      end
    end
  end
end
