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
