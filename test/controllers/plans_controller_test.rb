require "test_helper"

class PlansControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:one)
    @collaborator = users(:two)
    @creative = creatives(:tshirt)
    CreativeShare.delete_all
    CalendarEvent.delete_all
  end

  test "creative owner sees calendar events from collaborators" do
    CreativeShare.create!(creative: @creative, user: @collaborator, permission: :write)
    event = create_event(user: @collaborator, creative: @creative, google_event_id: "collaborator-event")

    login_as(@owner)
    get plans_url(format: :json)

    assert_response :success
    assert_includes json_ids, "calendar_event_#{event.id}"
  end

  test "collaborator sees events linked to shared creative hierarchy" do
    CreativeShare.create!(creative: @creative, user: @collaborator, permission: :write)
    child_creative = Creative.create!(parent: @creative, description: "Child creative")
    assert child_creative.has_permission?(@collaborator, :write)
    event = create_event(user: @owner, creative: child_creative, google_event_id: "owner-child-event")

    login_as(@collaborator)
    get plans_url(format: :json)

    assert_response :success
    assert_includes json_ids, "calendar_event_#{event.id}"
  end

  test "does not show calendar events to users without write permission" do
    CreativeShare.create!(creative: @creative, user: @collaborator, permission: :feedback)
    event = create_event(user: @owner, creative: @creative, google_event_id: "limited-permission-event")

    login_as(@collaborator)
    get plans_url(format: :json)

    assert_response :success
    assert_not_includes json_ids, "calendar_event_#{event.id}"
  end

  test "does not show events from child creative if user has no access" do
    # User has write access to parent
    CreativeShare.create!(creative: @creative, user: @collaborator, permission: :write)

    # But has no_access to the child
    child_creative = Creative.create!(parent: @creative, description: "Child creative")
    CreativeShare.create!(creative: child_creative, user: @collaborator, permission: :no_access)

    # Event is in the inaccessible child
    event = create_event(user: @owner, creative: child_creative, google_event_id: "inaccessible-child-event")

    login_as(@collaborator)
    get plans_url(format: :json)

    assert_response :success
    assert_not_includes json_ids, "calendar_event_#{event.id}", "Event from no_access child should not be visible"
  end

  private

  def login_as(user)
    user.update!(email_verified_at: Time.current)
    post session_path, params: { email: user.email, password: "password" }
  end

  def create_event(user:, creative:, google_event_id:)
    CalendarEvent.create!(
      user: user,
      creative: creative,
      google_event_id: google_event_id,
      summary: "Timeline event",
      start_time: Time.zone.now,
      end_time: Time.zone.now + 1.hour,
      html_link: "https://example.com/#{google_event_id}"
    )
  end

  def json_ids
    JSON.parse(response.body).map { |item| item["id"] }
  end
end
