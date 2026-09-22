# frozen_string_literal: true

require "test_helper"

module Collavre
  class CreativeWorkflowTest < ActiveSupport::TestCase
    test "workflow? identifies workflow metadata" do
      creative = Creative.new(data: { "kind" => "workflow" })

      assert_predicate creative, :workflow?
      refute_predicate creative, :workflow_rule?
    end

    test "workflow_rule? identifies workflow rule metadata" do
      creative = Creative.new(data: { "kind" => "workflow_rule" })

      assert_predicate creative, :workflow_rule?
      refute_predicate creative, :workflow?
    end

    test "workflow predicates are false without matching metadata" do
      creative = Creative.new

      refute_predicate creative, :workflow?
      refute_predicate creative, :workflow_rule?
    end

    [ [], [ { "kind" => "workflow" } ], "workflow", 42, 1.5, true, false, nil ].each do |metadata|
      test "workflow predicates are false for non-object metadata #{metadata.inspect}" do
        creative = Creative.new(data: metadata)

        refute_predicate creative, :workflow?
        refute_predicate creative, :workflow_rule?
      end
    end
  end
end
