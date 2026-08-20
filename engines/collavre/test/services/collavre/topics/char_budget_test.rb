# frozen_string_literal: true

require "test_helper"

module Collavre
  module Topics
    class CharBudgetTest < ActiveSupport::TestCase
      def sample(content: "hello", author: "Ann")
        { id: 12, author: author, author_id: 3, agent: false,
          created_at: "2026-08-19T10:23:45+09:00", content: content }
      end

      test "markdown charges the rendered envelope on top of the prose" do
        budget = CharBudget.new(format: "markdown")

        assert_equal CharBudget::ENVELOPE_CHARS + 5 + 3, budget.cost(sample)
      end

      # The undercount this class exists to fix: json restates every field name
      # and delimiter, so a message with no prose at all already costs well over
      # a hundred characters that markdown's envelope constant does not
      # describe. Charging markdown's number for a json response is what let a
      # few dozen short messages sail past max_chars.
      test "json charges the serialized form, so an empty message is already expensive" do
        empty = sample(content: "")
        overhead = CharBudget.new(format: "json").cost(empty) - CharBudget.new(format: "markdown").cost(empty)

        assert_operator overhead, :>=, 60
      end

      # The other half: escaping. No fixed constant tracks this, because the
      # ratio depends on the message rather than on the schema.
      test "json charges escaping, so quote-heavy prose costs more than its length" do
        budget = CharBudget.new(format: "json")
        plain = "a" * 100
        quoted = '"' * 100

        assert_operator budget.cost(sample(content: quoted)), :>, budget.cost(sample(content: plain))
      end

      test "an unknown or missing format falls back to markdown rather than raising" do
        assert_equal "markdown", CharBudget.new(format: "yaml").format
        assert_equal "markdown", CharBudget.new.format
        assert_equal "json", CharBudget.new(format: :json).format
      end

      # fits? decides before keeping. Asking "have I already overspent?"
      # afterwards let a message wider than the entire cap through untouched.
      test "fits? refuses a message that would cross the cap, not one that already has" do
        budget = CharBudget.new(chars: 50, format: "markdown")

        assert_not budget.fits?(budget.cost(sample(content: "x" * 100)))
        assert budget.fits?(budget.cost(sample(content: "x")))
      end

      test "fits? counts what has already been spent" do
        budget = CharBudget.new(chars: 100, format: "markdown")
        cost = budget.cost(sample(content: "x" * 10))

        assert budget.fits?(cost, spent: 0)
        assert_not budget.fits?(cost, spent: 60)
      end

      test "an unlimited budget fits everything" do
        budget = CharBudget.new(chars: nil, format: "json")

        assert budget.unlimited?
        assert budget.fits?(1_000_000, spent: 1_000_000)
      end

      test "with carries the format onto a new cap" do
        derived = CharBudget.new(chars: 100, format: "json").with(chars: 20)

        assert_equal 20, derived.chars
        assert_equal "json", derived.format
      end
    end
  end
end
