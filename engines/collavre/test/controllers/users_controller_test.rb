require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:one)
    @regular_user = users(:two)
  end

  test "non admin cannot access user index" do
    sign_in_as(@regular_user, password: "password")

    get collavre.users_path
    get collavre.users_path
    assert_response :not_found
  end

  test "system admin can access user index" do
    sign_in_as(@admin, password: "password")

    get collavre.users_path
    assert_response :success
    assert_includes response.body, @regular_user.email
  end

  test "non admin cannot grant system admin" do
    sign_in_as(@regular_user, password: "password")

    patch collavre.grant_system_admin_user_path(@regular_user)

    patch collavre.grant_system_admin_user_path(@regular_user)

    assert_response :not_found
    assert_not @regular_user.reload.system_admin?
  end

  test "non admin cannot revoke system admin" do
    sign_in_as(@regular_user, password: "password")

    patch collavre.revoke_system_admin_user_path(@admin)

    patch collavre.revoke_system_admin_user_path(@admin)

    assert_response :not_found
    assert @admin.reload.system_admin?
  end

  test "system admin can grant system admin" do
    sign_in_as(@admin, password: "password")

    refute @regular_user.system_admin?

    patch collavre.grant_system_admin_user_path(@regular_user)

    assert_redirected_to collavre.users_path
    follow_redirect!
    assert_equal I18n.t("collavre.users.system_admin.granted"), flash[:notice]
    assert @regular_user.reload.system_admin?
  end

  test "system admin can revoke system admin" do
    sign_in_as(@admin, password: "password")

    @regular_user.update!(system_admin: true)

    patch collavre.revoke_system_admin_user_path(@regular_user)

    assert_redirected_to collavre.users_path
    follow_redirect!
    assert_equal I18n.t("collavre.users.system_admin.revoked"), flash[:notice]
    refute @regular_user.reload.system_admin?
  end

  test "system admin cannot delete themselves" do
    sign_in_as(@admin, password: "password")

    assert_no_difference("User.count") do
      delete collavre.user_path(@admin)
    end

    assert_redirected_to collavre.users_path
    follow_redirect!
    assert_equal I18n.t("collavre.users.destroy.cannot_delete_self"), flash[:alert]
  end

  test "system admin can delete a user and all associated data" do
    sign_in_as(@admin, password: "password")

    user_to_delete = @regular_user
    creative = Creative.create!(user: user_to_delete, description: "Test creative")
    comment = Comment.create!(creative: creative, user: user_to_delete, content: "Test comment")
    pointer = CommentReadPointer.create!(user: user_to_delete, creative: creative, last_read_comment: comment)
    expanded_state = UserCreativePreference.create!(user: user_to_delete, creative: creative, expanded_status: { creative.id => true })
    share = CreativeShare.create!(creative: creative, user: user_to_delete, permission: :read)
    calendar_event = CalendarEvent.create!(
      user: user_to_delete,
      creative: creative,
      google_event_id: "evt-123",
      start_time: Time.current,
      end_time: 1.hour.from_now
    )
    device = Device.create!(
      user: user_to_delete,
      client_id: "client-#{SecureRandom.uuid}",
      device_type: :web,
      fcm_token: "fcm-#{SecureRandom.uuid}"
    )
    email = Email.create!(user: user_to_delete, email: user_to_delete.email, subject: "Test", event: :invitation)

    # Stub push notification to avoid calling Firebase API
    inbox_item = nil
    PushNotificationJob.stub :perform_later, nil do
      inbox_item = InboxItem.create!(owner: user_to_delete, message_key: "test.key", message_params: {})
    end

    invitation = Invitation.create!(inviter: user_to_delete, creative: creative, permission: :read)
    plan_creative = Creative.create!(user: user_to_delete, description: "Sample Plan")
    plan = Plan.create!(owner: user_to_delete, creative: plan_creative, target_date: Date.current)
    tag = Tag.create!(label: plan, creative_id: creative.id)
    session = user_to_delete.sessions.create!(user_agent: "TestAgent", ip_address: "127.0.0.1")

    delete_called = false
    fake_calendar_service = Object.new
    fake_calendar_service.define_singleton_method(:delete_event) do |event_id|
      delete_called = true if event_id == "evt-123"
      true
    end

    Collavre::GoogleCalendarService.stub :new, ->(**_) { fake_calendar_service } do
      assert_difference("User.count", -1) do
        delete collavre.user_path(user_to_delete)
      end
    end

    assert delete_called, "Expected delete_event to be called"

    assert_redirected_to collavre.users_path
    follow_redirect!
    assert_equal I18n.t("collavre.users.destroy.success"), flash[:notice]

    refute User.exists?(user_to_delete.id)
    refute Creative.exists?(creative.id)
    refute Comment.exists?(comment.id)
    refute CommentReadPointer.exists?(pointer.id)
    refute UserCreativePreference.exists?(expanded_state.id)
    refute CreativeShare.exists?(share.id)
    refute CalendarEvent.exists?(calendar_event.id)
    refute Device.exists?(device.id)
    refute Email.exists?(email.id)
    refute InboxItem.exists?(inbox_item.id)
    refute Invitation.exists?(invitation.id)
    refute Plan.exists?(plan.id)
    refute Tag.exists?(tag.id)
    refute Session.exists?(session.id)
  end

  test "ai user creator can delete their ai user without being admin" do
    sign_in_as(@regular_user, password: "password")

    ai_user = User.create!(
      name: "MyBot",
      email: "mybot@ai.local",
      password: "password",
      llm_vendor: "google",
      llm_model: "gemini-3-flash-preview",
      system_prompt: "You are a bot.",
      created_by_id: @regular_user.id,
      email_verified_at: Time.current
    )

    assert_difference("User.count", -1) do
      delete collavre.user_path(ai_user)
    end

    assert_redirected_to collavre.user_path(@regular_user, tab: "contacts")
    follow_redirect!
    assert_equal I18n.t("collavre.users.destroy.success"), flash[:notice]
  end

  test "non creator non admin cannot delete ai user" do
    sign_in_as(@regular_user, password: "password")

    creator = User.create!(
      email: "creator@example.com",
      password: "password",
      password_confirmation: "password",
      name: "Creator"
    )

    ai_user = User.create!(
      name: "MyBot",
      email: "mybot2@ai.local",
      password: "password",
      llm_vendor: "google",
      llm_model: "gemini-3-flash-preview",
      system_prompt: "You are a bot.",
      created_by_id: creator.id,
      email_verified_at: Time.current
    )

    assert_no_difference("User.count") do
      delete collavre.user_path(ai_user)
    end

    assert_redirected_to collavre.user_path(@regular_user, tab: "contacts")
    follow_redirect!
    assert_equal I18n.t("collavre.users.destroy.not_authorized"), flash[:alert]
  end

  test "destroying user with hierarchical creatives succeeds (closure_tree leaf-first)" do
    sign_in_as(@admin, password: "password")

    target_user = User.create!(
      name: "DeleteMe",
      email: "deleteme@example.com",
      password: "password",
      email_verified_at: Time.current
    )
    ai_agent = User.create!(
      name: "AgentToDelete",
      email: "agent-delete@ai.local",
      password: "password",
      llm_vendor: "google",
      llm_model: "gemini-3-flash-preview",
      system_prompt: "Bot",
      created_by_id: target_user.id,
      email_verified_at: Time.current
    )

    root = Creative.create!(user: target_user, description: "Root")
    child = Creative.create!(user: target_user, description: "Child", parent: root)
    grandchild = Creative.create!(user: target_user, description: "Grandchild", parent: child)
    root2 = Creative.create!(user: target_user, description: "Root2")
    _linked = Creative.create!(user: target_user, parent: root2, origin_id: child.id)

    assert_difference("User.count", -2) do
      delete collavre.user_path(ai_agent)
      delete collavre.user_path(target_user)
    end

    assert_equal 0, Creative.where(user_id: target_user.id).count
  end

  test "unassigned AI agents appear in org chart, regular users do not" do
    sign_in_as(@admin, password: "password")

    # Create an unassigned AI agent owned by admin
    ai_agent = User.create!(
      name: "UnassignedBot",
      email: "unassigned-bot@ai.local",
      password: "password",
      llm_vendor: "google",
      llm_model: "gemini-3-flash-preview",
      system_prompt: "You are a bot.",
      created_by_id: @admin.id,
      email_verified_at: Time.current
    )

    # Create a regular unassigned contact (should NOT appear)
    regular_user = User.create!(
      email: "regular-unassigned@example.com",
      password: "password",
      password_confirmation: "password",
      name: "Regular Unassigned"
    )
    Collavre::Contact.ensure(user: @admin, contact_user: regular_user)

    get collavre.user_path(@admin, tab: "contacts", contacts_view: "org_chart")
    assert_response :success

    assert_includes response.body, ai_agent.email,
                    "Admin should see unassigned AI agent in org chart"
    assert_includes response.body, ai_agent.name,
                    "Admin should see unassigned AI agent's name in org chart"
    refute_includes response.body, regular_user.email,
                    "Regular unassigned contact should NOT appear in org chart"
  end

  test "mention search includes feedback permitted users even if not searchable" do
    sign_in_as(@regular_user, password: "password")

    creative = Creative.create!(user: @regular_user, description: "Searchable creative")
    permitted = User.create!(
      email: "feedback@example.com",
      password: "password",
      password_confirmation: "password",
      name: "Feedback User",
      searchable: false
    )
    impostor = User.create!(
      email: "feedback-impostor@example.com",
      password: "password",
      password_confirmation: "password",
      name: "Feedback Impostor",
      searchable: false
    )
    CreativeShare.create!(creative: creative, user: permitted, permission: :feedback)

    get collavre.search_users_path, params: { q: "feedback", creative_id: creative.id }
    assert_response :success
    results = JSON.parse(response.body)

    emails = results.map { |u| u["email"] }
    assert_includes emails, permitted.email
    refute_includes emails, impostor.email
  end

  test "mention search falls back to searchable users without creative context" do
    sign_in_as(@regular_user, password: "password")

    searchable_user = User.create!(
      email: "searchable@example.com",
      password: "password",
      password_confirmation: "password",
      name: "Searchable User",
      searchable: true
    )
    User.create!(
      email: "hidden@example.com",
      password: "password",
      password_confirmation: "password",
      name: "Hidden User",
      searchable: false
    )

    get collavre.search_users_path, params: { q: "searchable" }
    assert_response :success
    results = JSON.parse(response.body)

    emails = results.map { |u| u["email"] }
    assert_includes emails, searchable_user.email
    assert_equal 1, results.length
  end

  test "ai user defaults to non-searchable when checkbox is unchecked" do
    sign_in_as(@regular_user, password: "password")

    assert_difference("User.count", 1) do
      post collavre.create_ai_users_path, params: {
        ai_id: "nobot",
        name: "No Bot",
        system_prompt: "You are a helpful bot.",
        llm_model: User::SUPPORTED_LLM_MODELS.first
      }
    end

    ai_user = User.find_by(email: "nobot@ai.local")
    assert_not_nil ai_user
    refute ai_user.searchable?

    assert_redirected_to collavre.user_path(@regular_user, tab: "contacts")
    follow_redirect!
    assert_equal I18n.t("collavre.users.create_ai.success"), flash[:notice]
  end

  test "ai user creator sees edit button in org chart" do
    sign_in_as(@regular_user, password: "password")

    ai_user = User.create!(
      name: "MyBot",
      email: "mybot3@ai.local",
      password: "password",
      llm_vendor: "google",
      llm_model: "gemini-3-flash-preview",
      system_prompt: "You are a bot.",
      created_by_id: @regular_user.id,
      email_verified_at: Time.current
    )

    creative = Collavre::Creative.create!(user: @regular_user, description: "TestProject")
    Collavre::CreativeShare.create!(creative: creative, user: ai_user, shared_by: @regular_user, permission: :feedback)
    Collavre::Creatives::PermissionCacheBuilder.rebuild_for_creative(creative)

    get collavre.user_path(@regular_user, tab: "contacts")
    assert_response :success
    assert_includes response.body, I18n.t("collavre.users.edit_ai.link")
  end

  test "non creator does not see edit button for ai user in org chart" do
    sign_in_as(@regular_user, password: "password")

    creator = User.create!(
      email: "creator2@example.com",
      password: "password",
      password_confirmation: "password",
      name: "Creator2"
    )

    ai_user = User.create!(
      name: "OtherBot",
      email: "otherbot@ai.local",
      password: "password",
      llm_vendor: "google",
      llm_model: "gemini-3-flash-preview",
      system_prompt: "You are a bot.",
      created_by_id: creator.id,
      email_verified_at: Time.current
    )

    creative = Collavre::Creative.create!(user: @regular_user, description: "TestProject2")
    Collavre::CreativeShare.create!(creative: creative, user: ai_user, shared_by: @regular_user, permission: :feedback)
    Collavre::Creatives::PermissionCacheBuilder.rebuild_for_creative(creative)

    get collavre.user_path(@regular_user, tab: "contacts")
    assert_response :success
    refute_includes response.body, I18n.t("collavre.users.edit_ai.link")
  end
  test "search with scope contacts returns contact users" do
    sign_in_as(@admin, password: "password")

    # @admin (one) has contact @regular_user (two) from fixtures
    get collavre.search_users_path, params: { q: "two", scope: "contacts" }
    assert_response :success
    results = JSON.parse(response.body)

    assert_equal 1, results.length
    assert_equal @regular_user.email, results.first["email"]
  end

  test "search with scope contacts allows empty query" do
    sign_in_as(@admin, password: "password")

    get collavre.search_users_path, params: { q: "", scope: "contacts" }
    assert_response :success
    results = JSON.parse(response.body)

    # Should return contacts (at least one from fixtures)
    assert_operator results.length, :>=, 1
    emails = results.map { |u| u["email"] }
    assert_includes emails, @regular_user.email
  end

  test "search with scope contacts respects limit" do
    sign_in_as(@admin, password: "password")

    # Create more contacts
    25.times do |i|
      u = User.create!(email: "contact#{i}@example.com", password: "password", name: "Contact #{i}")
      Contact.create!(user: @admin, contact_user: u)
    end

    get collavre.search_users_path, params: { q: "", scope: "contacts", limit: 10 }
    assert_response :success
    results = JSON.parse(response.body)
    assert_equal 10, results.length

    # Default limit 20
    get collavre.search_users_path, params: { q: "", scope: "contacts" }
    results = JSON.parse(response.body)
    assert_equal 20, results.length
  end

  test "search returns correct json structure" do
    sign_in_as(@admin, password: "password")

    get collavre.search_users_path, params: { q: "two", scope: "contacts" }
    assert_response :success
    result = JSON.parse(response.body).first

    assert_equal @regular_user.id, result["id"]
    assert_equal @regular_user.name, result["name"] # Should be name, not display_name if controller maps it
    assert_equal @regular_user.email, result["email"]
    assert result.key?("avatar_url")
  end
  test "non admin user cannot access other user's passkeys page" do
    sign_in_as(@regular_user, password: "password")
    other_user = users(:one) # admin user

    get collavre.passkeys_user_path(other_user)

    assert_redirected_to collavre.user_path(@regular_user)
    assert_equal I18n.t("collavre.users.destroy.not_authorized"), flash[:alert]
  end

  test "user can access their own passkeys page" do
    sign_in_as(@regular_user, password: "password")

    get collavre.passkeys_user_path(@regular_user)
    assert_response :success
  end

  test "system admin can access other user's passkeys page" do
    sign_in_as(@admin, password: "password")

    get collavre.passkeys_user_path(@regular_user)
    assert_response :success
  end
  test "admin link appears in profile for system admin" do
    sign_in_as(@admin, password: "password")
    get collavre.user_path(@admin)
    assert_response :success
    assert_select "a[href=?]", admin_path
  end

  test "admin link does not appear in profile for regular user" do
    sign_in_as(@regular_user, password: "password")
    get collavre.user_path(@regular_user)
    assert_response :success
    assert_select "a[href=?]", admin_path, count: 0
  end

  test "ai user creation succeeds when password_min_length is set to max (72)" do
    sign_in_as(@regular_user, password: "password")

    # Set password_min_length to maximum (72)
    SystemSetting.find_or_create_by!(key: "password_min_length").update!(value: "72")
    Rails.cache.clear

    assert_difference("User.count", 1) do
      post collavre.create_ai_users_path, params: {
        ai_id: "maxbot",
        name: "Max Bot",
        system_prompt: "You are a helpful bot.",
        llm_model: User::SUPPORTED_LLM_MODELS.first
      }
    end

    ai_user = User.find_by(email: "maxbot@ai.local")
    assert_not_nil ai_user
    assert_redirected_to collavre.user_path(@regular_user, tab: "contacts")
  ensure
    SystemSetting.find_by(key: "password_min_length")&.destroy
    Rails.cache.clear
  end
end
