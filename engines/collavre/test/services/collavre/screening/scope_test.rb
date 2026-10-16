# frozen_string_literal: true

require "test_helper"

module Collavre
  module Screening
    class ScopeTest < ActiveSupport::TestCase
      setup do
        @owner = users(:one)
        @other = users(:two)
        @agent = Struct.new(:created_by_id).new(@owner.id)
      end

      test "owner turns and principal-less system turns are skipped" do
        assert_equal :skip, Scope.for(agent: @agent, context: {}, principal: @owner)
        assert_equal :skip, Scope.for(agent: @agent, context: {}, principal: nil)
        assert_equal :skip, Scope.for(agent: @agent, context: nil, principal: nil)
      end

      test "another person's turn is screened" do
        assert_equal :screen, Scope.for(agent: @agent, context: {}, principal: @other)
      end

      test "a carried principal that cannot be verified is screened" do
        assert_equal :screen, Scope.for(agent: @agent, context: { "workspace_user_id" => nil }, principal: nil)
      end

      test "text from someone other than the owner is screened whoever the principal is" do
        agent = User.create!(email: "scope-#{SecureRandom.hex(3)}@agent.collavre.local", name: "Scoped",
          password: SecureRandom.hex(16), llm_vendor: "google", llm_model: "g", created_by_id: @owner.id)
        sibling = User.create!(email: "sibling-#{SecureRandom.hex(3)}@agent.collavre.local", name: "Sibling",
          password: SecureRandom.hex(16), llm_vendor: "google", llm_model: "g", created_by_id: @owner.id)
        foreign = User.create!(email: "foreign-#{SecureRandom.hex(3)}@agent.collavre.local", name: "Foreign",
          password: SecureRandom.hex(16), llm_vendor: "google", llm_model: "g", created_by_id: @other.id)
        assert_equal :skip, Scope.for(agent: agent, context: {}, principal: @owner, authors: [ @owner, agent, sibling ])
        assert_equal :screen, Scope.for(agent: agent, context: {}, principal: @owner, authors: [ foreign ])
        assert_equal :screen, Scope.for(agent: agent, context: {}, principal: nil, authors: [ @other ])
        agent.update_columns(created_by_id: nil)
        assert_equal :screen, Scope.for(agent: agent.reload, context: {}, principal: nil, authors: [ sibling ])
      end

      test "an agent without an owner screens every human" do
        agent = Struct.new(:created_by_id).new(nil)
        assert_equal :screen, Scope.for(agent: agent, context: {}, principal: @owner)
      end
    end
  end
end
