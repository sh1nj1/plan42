# frozen_string_literal: true

require "test_helper"

class CronsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @creative = Collavre::Creative.create!(user: @user, description: "Scheduled work")
    @topic = @creative.main_topic(fallback_user: @user)
    @task = create_task(@creative, @topic)
    sign_in_as @user, password: "password"
  end

  teardown do
    @task.destroy! if @task&.persisted?
  end

  test "destroys a cron belonging to the writable creative and broadcasts the change" do
    assert_broadcast_on(Collavre::TopicsChannel.broadcasting_for(@creative), action: "cron_changed") do
      delete collavre.creative_cron_url(@creative, @task.key), as: :json
    end

    assert_response :no_content
    assert_not @task.class.exists?(@task.id)
  end

  test "updates a cron message while preserving its other arguments" do
    assert_broadcast_on(Collavre::TopicsChannel.broadcasting_for(@creative), action: "cron_changed") do
      patch collavre.creative_cron_url(@creative, @task.key), params: { message: "Updated summary" }, as: :json
    end

    assert_response :success
    assert_equal({ "message" => "Updated summary" }, response.parsed_body)

    arguments = @task.reload.arguments.first.stringify_keys
    assert_equal "Updated summary", arguments.fetch("message")
    assert_equal @creative.id, arguments.fetch("creative_id")
    assert_equal @topic.id, arguments.fetch("topic_id")
  end

  test "rejects an empty cron message" do
    patch collavre.creative_cron_url(@creative, @task.key), params: { message: "" }, as: :json

    assert_response :unprocessable_entity
    assert_equal I18n.t("collavre.crons.message_required"), response.parsed_body.fetch("error")
    assert_equal "Daily summary", @task.reload.arguments.first.stringify_keys.fetch("message")
  end

  test "returns an update service error" do
    calls = []
    service = Object.new
    service.define_singleton_method(:call) do |**arguments|
      calls << arguments
      { error: "Cron update failed" }
    end

    Collavre::Tools::CronUpdateService.stub(:new, -> { service }) do
      patch collavre.creative_cron_url(@creative, @task.key), params: { message: "Updated summary" }, as: :json
    end

    assert_response :unprocessable_entity
    assert_equal "Cron update failed", response.parsed_body.fetch("error")
    assert_equal [ { key: @task.key, message: "Updated summary" } ], calls
  end

  test "rejects message updates without write permission" do
    sign_in_as users(:two), password: "password"

    patch collavre.creative_cron_url(@creative, @task.key), params: { message: "Not allowed" }, as: :json

    assert_response :forbidden
    assert_equal "Daily summary", @task.reload.arguments.first.stringify_keys.fetch("message")
  end

  test "does not update a cron belonging to another creative" do
    other_creative = Collavre::Creative.create!(user: @user, description: "Other work")

    patch collavre.creative_cron_url(other_creative, @task.key), params: { message: "Wrong creative" }, as: :json

    assert_response :not_found
    assert_equal "Daily summary", @task.reload.arguments.first.stringify_keys.fetch("message")
  end

  test "rejects deletion without write permission" do
    other_user = users(:two)
    sign_in_as other_user, password: "password"

    delete collavre.creative_cron_url(@creative, @task.key), as: :json

    assert_response :forbidden
    assert @task.class.exists?(@task.id)
  end

  test "does not delete a cron belonging to another creative" do
    other_creative = Collavre::Creative.create!(user: @user, description: "Other work")

    delete collavre.creative_cron_url(other_creative, @task.key), as: :json

    assert_response :not_found
    assert @task.class.exists?(@task.id)
  end

  test "scopes recurring task lookup to the writable creative family" do
    index = Minitest::Mock.new
    index.expect(:tasks_for, [ @task ], [ @creative.id ])
    scope = lambda do |creative|
      assert_equal @creative, creative
      index
    end

    Collavre::Crons::RecurringTaskIndex.stub(:for_creative_family, scope) do
      delete collavre.creative_cron_url(@creative, @task.key), as: :json
    end

    assert_response :no_content
    assert_mock index
  end

  private

  def create_task(creative, topic)
    SolidQueue::RecurringTask.create!(
      key: "cron_#{creative.id}_#{SecureRandom.hex(4)}",
      class_name: "Collavre::CronActionJob",
      schedule: "0 9 * * *",
      static: false,
      arguments: [ { creative_id: creative.id, topic_id: topic.id, message: "Daily summary" } ]
    )
  end
end
