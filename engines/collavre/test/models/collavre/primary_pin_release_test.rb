require "test_helper"

module Collavre
  class PrimaryPinReleaseTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    setup do
      @initial_topic_ids = Topic.ids
      @agent = users(:ai_bot)
      @original_vendor = @agent.llm_vendor
      @creative = Creative.create!(description: "Pin release", user: users(:one))
      @topics = 2.times.map do |index|
        @creative.topics.create!(name: "Release #{index}", user: users(:one), primary_agent: @agent)
      end
      @session = @creative.topics.create!(name: "Session", user: users(:one), primary_agent: @agent, session_id: "session")
    end

    teardown do
      Topic.where.not(id: @initial_topic_ids).destroy_all if @initial_topic_ids
      @creative&.destroy!
      @agent&.update_columns(llm_vendor: @original_vendor)
    end

    test "pin releases broadcast explicit cleared agents only after commit" do
      broadcasts = []
      TopicsChannel.stub(:broadcast_to, ->(creative, payload) { broadcasts << [ creative.id, payload ] }) do
        User.transaction do
          @agent.update!(llm_vendor: "typesafe")
          assert_empty broadcasts
          @topics.each { |topic| assert_nil topic.reload.primary_agent_id }
        end
      end
      assert_equal @topics.map(&:id).sort, broadcasts.map { |_, payload| payload[:topic]["id"] }.sort
      broadcasts.each do |creative_id, payload|
        assert_equal @creative.id, creative_id
        assert_equal "updated", payload[:action]
        assert payload[:topic].key?(:primary_agent)
        assert_nil payload[:topic][:primary_agent]
      end
      assert_equal @agent.id, @session.reload.primary_agent_id
    end

    test "rolled back vendor changes preserve pins without broadcasting" do
      TopicsChannel.stub(:broadcast_to, ->(*) { flunk "rollback must not broadcast" }) do
        User.transaction do
          @agent.update!(llm_vendor: "typesafe")
          raise ActiveRecord::Rollback
        end
      end
      @topics.each { |topic| assert_equal @agent.id, topic.reload.primary_agent_id }
    end

    test "chat vendor changes keep pins without broadcasting" do
      TopicsChannel.stub(:broadcast_to, ->(*) { flunk "chat vendor must not release pins" }) do
        @agent.update!(llm_vendor: "google")
      end
      @topics.each { |topic| assert_equal @agent.id, topic.reload.primary_agent_id }
    end
  end
end
