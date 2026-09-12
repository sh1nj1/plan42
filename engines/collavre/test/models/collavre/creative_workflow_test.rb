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
  end
end
