require "test_helper"

class PlansTimelineItemsTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:one)
    @owner.update!(email_verified_at: Time.current)
    CalendarEvent.delete_all
    @creative = Creative.create!(user: @owner, description: "<b>Anchor</b> & 'quoted'")
    @creative.update_column(:updated_at, @creative.created_at + 1.hour)
    @plan = Plan.create!(creative: @creative, target_date: Date.current + 5.days, owner: @owner)
    @linked_event = create_event("linked", creative: @creative, summary: "Linked event")
    @unlinked_event = create_event("unlinked", creative: nil, summary: nil)
    post session_path, params: { email: @owner.email, password: "password" }
  end

  test "index json items keep their exact shape" do
    get collavre_plan_engine.plans_path(format: :json, registrations: 1, modifications: 1)

    assert_response :success
    items = JSON.parse(response.body).index_by { |item| item["id"] }
    created_on = @creative.created_at.to_date.to_s
    assert_equal({
      "id" => @plan.id, "name" => "Anchor & 'quoted'", "created_at" => @plan.created_at.to_date.to_s,
      "start_date" => created_on, "target_date" => (Date.current + 5.days).to_s, "progress" => @plan.progress,
      "path" => "/creatives?tags%5B%5D=#{@plan.id}", "deletable" => true
    }, items[@plan.id])
    assert_equal({
      "id" => "calendar_event_#{@linked_event.id}", "name" => "Linked event",
      "created_at" => @linked_event.start_time.to_date.to_s, "target_date" => @linked_event.end_time.to_date.to_s,
      "progress" => @creative.progress, "path" => "/creatives/#{@creative.id}", "deletable" => true
    }, items["calendar_event_#{@linked_event.id}"])
    unlinked = items["calendar_event_#{@unlinked_event.id}"]
    assert_equal I18n.l(@unlinked_event.start_time.to_date), unlinked["name"]
    assert_equal 0, unlinked["progress"]
    assert_equal "https://example.com/unlinked", unlinked["path"]
    assert_equal({
      "id" => "modification_#{@creative.id}", "type" => "modification", "name" => "Anchor & 'quoted'",
      "created_at" => @creative.updated_at.to_date.to_s, "target_date" => @creative.updated_at.to_date.to_s,
      "progress" => @creative.progress, "path" => "/creatives/#{@creative.id}", "deletable" => false
    }, items["modification_#{@creative.id}"])
    registered = Creative.create!(user: @owner, description: "Registered")
    get collavre_plan_engine.plans_path(format: :json, registrations: 1)
    assert_equal({
      "id" => "registration_#{registered.id}", "type" => "registration", "name" => "Registered",
      "created_at" => registered.created_at.to_date.to_s, "target_date" => registered.created_at.to_date.to_s,
      "progress" => registered.progress, "path" => "/creatives/#{registered.id}", "deletable" => false
    }, JSON.parse(response.body).find { |item| item["id"] == "registration_#{registered.id}" })
  end

  test "timeline html embeds the same items as the json endpoint" do
    Creative.create!(user: @owner, description: "Registered")
    [ {}, { id: @creative.id } ].each do |extra|
      query = { registrations: 1, modifications: 1 }.merge(extra)
      get collavre_plan_engine.plans_path(query)
      assert_response :success
      embedded = response.body[/data-plans='(.*?)' data-start-date/m, 1]
      get collavre_plan_engine.plans_path(query.merge(format: :json))

      assert_equal response.body, embedded
      assert_operator JSON.parse(embedded).size, :>=, 5
    end
  end

  test "html and json agree when the app is served under a script name" do
    get "/plans", params: { id: @creative.id, registrations: 1 }, env: { "SCRIPT_NAME" => "/sub" }
    assert_response :success
    embedded = response.body[/data-plans='(.*?)' data-start-date/m, 1]
    get "/plans.json", params: { id: @creative.id, registrations: 1 }, env: { "SCRIPT_NAME" => "/sub" }

    assert_equal response.body, embedded
    assert_equal "/sub", request.script_name
    assert_equal "/creatives/#{@creative.id}?tags%5B%5D=#{@plan.id}", JSON.parse(embedded).first["path"]
  end

  test "plan path prefers the current creative id" do
    get collavre_plan_engine.plans_path(format: :json, id: @creative.id)

    paths = JSON.parse(response.body).index_by { |item| item["id"] }
    assert_equal "/creatives/#{@creative.id}?tags%5B%5D=#{@plan.id}", paths[@plan.id]["path"]
  end

  test "create json returns the plan item" do
    post collavre_plan_engine.plans_path(format: :json), params: { plan: { target_date: Date.current, creative_id: @creative.id } }

    assert_response :created
    plan = Plan.last
    body = JSON.parse(response.body)
    assert_equal plan.id, body["id"]
    assert_equal "/creatives?tags%5B%5D=#{plan.id}", body["path"]
    assert_equal true, body["deletable"]
  end

  test "create html redirects with notice" do
    post collavre_plan_engine.plans_path, params: { plan: { target_date: Date.current, creative_id: @creative.id } }

    assert_redirected_to "/"
    assert_equal I18n.t("collavre.plans.created"), flash[:notice]
  end

  test "create failure responds with errors" do
    post collavre_plan_engine.plans_path(format: :json), params: { plan: { target_date: "" } }
    assert_response :unprocessable_entity
    errors = JSON.parse(response.body)["errors"]
    assert_predicate errors, :any?

    post collavre_plan_engine.plans_path, params: { plan: { target_date: "" } }
    assert_redirected_to "/"
    assert_equal errors.join(", "), flash[:alert]
  end

  test "update json path uses creative_id param, then plan creative" do
    other = Creative.create!(user: @owner, description: "Other")
    patch collavre_plan_engine.plan_path(@plan, format: :json), params: { plan: { target_date: Date.current + 7.days }, creative_id: other.id }
    assert_response :ok
    assert_equal "/creatives/#{other.id}?tags%5B%5D=#{@plan.id}", JSON.parse(response.body)["path"]

    patch collavre_plan_engine.plan_path(@plan, format: :json), params: { plan: { target_date: Date.current + 8.days } }
    assert_equal "/creatives/#{@creative.id}?tags%5B%5D=#{@plan.id}", JSON.parse(response.body)["path"]
  end

  test "update html redirects with notice" do
    patch collavre_plan_engine.plan_path(@plan), params: { plan: { target_date: Date.current + 7.days } }

    assert_redirected_to "/"
    assert_equal "Plan updated.", flash[:notice]
  end

  test "update failure responds with errors" do
    patch collavre_plan_engine.plan_path(@plan, format: :json), params: { plan: { target_date: "" } }
    assert_response :unprocessable_entity
    errors = JSON.parse(response.body)["errors"]
    assert_predicate errors, :any?

    patch collavre_plan_engine.plan_path(@plan), params: { plan: { target_date: "" } }
    assert_redirected_to "/"
    assert_equal errors.join(", "), flash[:alert]
  end

  test "destroy removes the plan" do
    other_plan = Plan.create!(creative: @creative, target_date: Date.current + 2.days, owner: @owner)
    delete collavre_plan_engine.plan_path(@plan, format: :json)
    assert_response :no_content

    delete collavre_plan_engine.plan_path(other_plan)
    assert_redirected_to "/"
    assert_equal "Plan deleted.", flash[:notice]
    assert_equal 0, Plan.where(id: [ @plan.id, other_plan.id ]).count
  end

  test "destroy of a missing plan is not found" do
    delete collavre_plan_engine.plan_path(0, format: :json)

    assert_response :not_found
  end

  private

  def create_event(key, creative:, summary:)
    CalendarEvent.create!(user: @owner, creative: creative, google_event_id: key, summary: summary,
                          start_time: Time.zone.now, end_time: Time.zone.now + 1.hour,
                          html_link: "https://example.com/#{key}")
  end
end
