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
    perform_enqueued_jobs do
      CreativeShare.create!(creative: @creative, user: @collaborator, permission: :write)
    end
    event = create_event(user: @collaborator, creative: @creative, google_event_id: "collaborator-event")

    login_as(@owner)
    get collavre_plan_engine.plans_path(format: :json)

    assert_response :success
    assert_includes json_ids, "calendar_event_#{event.id}"
  end

  test "collaborator sees events linked to shared creative hierarchy" do
    child_creative = nil
    perform_enqueued_jobs do
      CreativeShare.create!(creative: @creative, user: @collaborator, permission: :write)
      child_creative = Creative.create!(parent: @creative, description: "Child creative")
    end
    assert child_creative.has_permission?(@collaborator, :write)
    event = create_event(user: @owner, creative: child_creative, google_event_id: "owner-child-event")

    login_as(@collaborator)
    get collavre_plan_engine.plans_path(format: :json)

    assert_response :success
    assert_includes json_ids, "calendar_event_#{event.id}"
  end

  test "does not show calendar events to users without write permission" do
    perform_enqueued_jobs do
      CreativeShare.create!(creative: @creative, user: @collaborator, permission: :feedback)
    end
    event = create_event(user: @owner, creative: @creative, google_event_id: "limited-permission-event")

    login_as(@collaborator)
    get collavre_plan_engine.plans_path(format: :json)

    assert_response :success
    assert_not_includes json_ids, "calendar_event_#{event.id}"
  end

  test "does not show events from child creative if user has no access" do
    child_creative = nil
    perform_enqueued_jobs do
      # User has write access to parent
      CreativeShare.create!(creative: @creative, user: @collaborator, permission: :write)

      # But has no_access to the child
      child_creative = Creative.create!(parent: @creative, description: "Child creative")
      CreativeShare.create!(creative: child_creative, user: @collaborator, permission: :no_access)
    end

    # Event is in the inaccessible child
    event = create_event(user: @owner, creative: child_creative, google_event_id: "inaccessible-child-event")

    login_as(@collaborator)
    get collavre_plan_engine.plans_path(format: :json)

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

  test "user with read permission on creative can see linked plan" do
    creative = creatives(:tshirt)
    collaborator = users(:two)

    perform_enqueued_jobs do
      CreativeShare.create!(creative: creative, user: collaborator, permission: :read)
    end
    plan = Plan.create!(target_date: Date.today, creative: creative, owner: users(:one))

    login_as(collaborator)
    get collavre_plan_engine.plans_path(format: :json)

    assert_response :success
    assert_includes json_ids, plan.id, "User with read permission should see Creative-linked plan"
  end

  test "user without permission on creative cannot see linked plan" do
    creative = creatives(:tshirt)
    plan = Plan.create!(target_date: Date.today, creative: creative, owner: users(:one))

    login_as(users(:two))
    get collavre_plan_engine.plans_path(format: :json)

    assert_response :success
    refute_includes json_ids, plan.id, "User without permission should not see Creative-linked plan"
  end

  test "create plan with creative_id" do
    creative = creatives(:tshirt)

    login_as(users(:one))
    assert_difference("Plan.count", 1) do
      post collavre_plan_engine.plans_path(format: :json), params: {
        plan: { target_date: Date.today, creative_id: creative.id }
      }
    end

    assert_response :created
    plan = Plan.last
    assert_equal creative.id, plan.creative_id, "Plan should be linked to Creative"
  end

  test "user with write permission on tagged creative can update plan dates" do
    creative = creatives(:tshirt)
    plan_creative = Creative.create!(user: @owner, description: "Plan Creative")
    plan = Plan.create!(target_date: Date.current + 5.days, creative: plan_creative, owner: @owner)
    plan.tags.create!(creative_id: creative.id)

    perform_enqueued_jobs do
      CreativeShare.create!(creative: creative, user: @collaborator, permission: :write)
    end

    login_as(@collaborator)
    new_start_date = Date.current + 1.day
    new_target_date = Date.current + 6.days
    patch collavre_plan_engine.plan_path(plan, format: :json), params: {
      plan: { start_date: new_start_date, target_date: new_target_date },
      creative_id: creative.id
    }

    assert_response :success
    plan.reload
    assert_equal new_start_date, plan.start_date
    assert_equal new_target_date, plan.target_date
  end

  test "user without edit permission gets 404 (not 403) when updating plan" do
    creative = creatives(:tshirt)
    plan = Plan.create!(target_date: Date.today, creative: creative, owner: @owner)

    login_as(@collaborator)
    patch collavre_plan_engine.plan_path(plan, format: :json),
          params: { plan: { target_date: Date.tomorrow } }

    assert_response :not_found
    assert_equal Date.today, plan.reload.target_date
  end

  test "user without edit permission gets 404 (not 403) when destroying plan" do
    creative = creatives(:tshirt)
    plan = Plan.create!(target_date: Date.today, creative: creative, owner: @owner)

    login_as(@collaborator)
    assert_no_difference("Plan.count") do
      delete collavre_plan_engine.plan_path(plan, format: :json)
    end

    assert_response :not_found
  end

  test "registration markers are excluded by default" do
    creative = Creative.create!(user: @owner, description: "Registered creative")

    login_as(@owner)
    get collavre_plan_engine.plans_path(format: :json)

    assert_response :success
    assert_not_includes json_ids, "registration_#{creative.id}", "Registrations should be off by default"
  end

  test "registration markers are included when chip is enabled" do
    creative = Creative.create!(user: @owner, description: "Registered creative")

    login_as(@owner)
    get collavre_plan_engine.plans_path(format: :json, registrations: 1)

    assert_response :success
    assert_includes json_ids, "registration_#{creative.id}", "Registrations should appear when requested"
  end

  test "registration markers are owner-scoped" do
    others_creative = Creative.create!(user: @collaborator, description: "Other user creative")

    login_as(@owner)
    get collavre_plan_engine.plans_path(format: :json, registrations: 1)

    assert_response :success
    assert_not_includes json_ids, "registration_#{others_creative.id}", "Should not show other users' registrations"
  end

  test "registration markers include day-edge creatives in the user's time zone" do
    @owner.update!(timezone: "Asia/Seoul")
    edge_creative = nil
    Time.use_zone("Asia/Seoul") do
      window_start = Date.current - 30
      edge_creative = Creative.create!(user: @owner, description: "Edge creative")
      # Local midnight on the window-start date stores as the previous UTC day;
      # the old DATE(created_at) cast dropped it, the local range keeps it.
      edge_creative.update_column(:created_at, window_start.beginning_of_day)
    end

    login_as(@owner)
    get collavre_plan_engine.plans_path(format: :json, registrations: 1)

    assert_response :success
    assert_includes json_ids, "registration_#{edge_creative.id}",
                    "Day-edge creative at local midnight should be included"
  end

  test "registration marker uses localized fallback when description strips to blank" do
    # HTML-only description (e.g. attachment markup) passes presence but strips to "".
    creative = Creative.create!(user: @owner, description: "<p></p>")

    login_as(@owner)
    get collavre_plan_engine.plans_path(format: :json, registrations: 1)

    assert_response :success
    entry = JSON.parse(response.body).find { |i| i["id"] == "registration_#{creative.id}" }
    assert_not_nil entry, "Blank-description creative should still render a marker"
    assert_equal "Creative ##{creative.id}", entry["name"]
  end

  test "modification markers are excluded by default" do
    creative = Creative.create!(user: @owner, description: "Modified creative")
    creative.update_column(:updated_at, creative.created_at + 1.day)

    login_as(@owner)
    get collavre_plan_engine.plans_path(format: :json)

    assert_response :success
    assert_not_includes json_ids, "modification_#{creative.id}", "Modifications should be off by default"
  end

  test "modification markers are included when chip is enabled" do
    creative = Creative.create!(user: @owner, description: "Modified creative")
    creative.update_column(:updated_at, creative.created_at + 1.day)

    login_as(@owner)
    get collavre_plan_engine.plans_path(format: :json, modifications: 1)

    assert_response :success
    assert_includes json_ids, "modification_#{creative.id}", "Modifications should appear when requested"
  end

  test "modification markers exclude never-modified creatives" do
    # updated_at == created_at (just created, never touched) — not a modification.
    creative = Creative.create!(user: @owner, description: "Untouched creative")

    login_as(@owner)
    get collavre_plan_engine.plans_path(format: :json, modifications: 1)

    assert_response :success
    assert_not_includes json_ids, "modification_#{creative.id}", "Never-modified creatives should not appear"
  end

  test "modification markers are owner-scoped" do
    others_creative = Creative.create!(user: @collaborator, description: "Other user creative")
    others_creative.update_column(:updated_at, others_creative.created_at + 1.day)

    login_as(@owner)
    get collavre_plan_engine.plans_path(format: :json, modifications: 1)

    assert_response :success
    assert_not_includes json_ids, "modification_#{others_creative.id}", "Should not show other users' modifications"
  end

  test "modification marker is drawn at updated_at" do
    creative = Creative.create!(user: @owner, description: "Modified creative")
    creative.update_column(:created_at, Date.current - 10)
    creative.update_column(:updated_at, Time.current)

    login_as(@owner)
    get collavre_plan_engine.plans_path(format: :json, modifications: 1)

    assert_response :success
    entry = JSON.parse(response.body).find { |i| i["id"] == "modification_#{creative.id}" }
    assert_not_nil entry, "Modified creative should render a marker"
    assert_equal creative.reload.updated_at.to_date.to_s, entry["target_date"], "Marker should sit at updated_at, not created_at"
  end

  test "registration markers exclude plan-anchor creatives" do
    # Plan#start_date= overwrites the anchor creative's created_at, so its
    # created_at is plan-managed (it already renders as a plan bar), not a true
    # registration — it must not also show a registration marker.
    creative = Creative.create!(user: @owner, description: "Plan anchor creative")
    plan = Plan.create!(creative: creative, target_date: Date.current + 5.days, owner: @owner)
    plan.start_date = Date.current - 3

    login_as(@owner)
    get collavre_plan_engine.plans_path(format: :json, registrations: 1)

    assert_response :success
    assert_not_includes json_ids, "registration_#{creative.id}",
                        "Plan-anchor creatives must not show a registration marker"
  end

  test "modification markers exclude plan-anchor creatives" do
    # Backdating start_date moves created_at into the past while update_column
    # leaves updated_at stale, so updated_at > created_at falsely looks "modified".
    # Excluding plan-anchor creatives prevents that false marker.
    creative = Creative.create!(user: @owner, description: "Plan anchor creative")
    plan = Plan.create!(creative: creative, target_date: Date.current + 5.days, owner: @owner)
    plan.start_date = Date.current - 3

    login_as(@owner)
    get collavre_plan_engine.plans_path(format: :json, modifications: 1)

    assert_response :success
    assert_not_includes json_ids, "modification_#{creative.id}",
                        "Plan-anchor creatives must not show a false modification marker"
  end

  test "should return stripped html in json" do
    creative = creatives(:tshirt)
    creative.update!(description: "<b>T-Shirt</b> <i>Design</i>")
    plan = Plan.create!(creative: creative, target_date: Date.today, owner: users(:one))

    login_as(users(:one))
    get collavre_plan_engine.plans_path(format: :json)
    assert_response :success

    json = JSON.parse(response.body)
    plan_json = json.find { |p| p["id"] == plan.id }
    assert_equal "T-Shirt Design", plan_json["name"], "HTML should be stripped from plan name"
  end
end
