require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:one)
    @regular_user = users(:two)
  end

  test "non admin cannot access user index" do
    sign_in_as(@regular_user, password: "password")

    get users_path
    get users_path
    assert_response :not_found
  end

  test "system admin can access user index" do
    sign_in_as(@admin, password: "password")

    get users_path
    assert_response :success
    assert_includes response.body, @regular_user.email
  end

  test "non admin cannot grant system admin" do
    sign_in_as(@regular_user, password: "password")

    patch grant_system_admin_user_path(@regular_user)

    patch grant_system_admin_user_path(@regular_user)

    assert_response :not_found
    assert_not @regular_user.reload.system_admin?
  end

  test "non admin cannot revoke system admin" do
    sign_in_as(@regular_user, password: "password")

    patch revoke_system_admin_user_path(@admin)

    patch revoke_system_admin_user_path(@admin)

    assert_response :not_found
    assert @admin.reload.system_admin?
  end

  test "system admin can grant system admin" do
    sign_in_as(@admin, password: "password")

    refute @regular_user.system_admin?

    patch grant_system_admin_user_path(@regular_user)

    assert_redirected_to users_path
    follow_redirect!
    assert_equal I18n.t("users.system_admin.granted"), flash[:notice]
    assert @regular_user.reload.system_admin?
  end

  test "system admin can revoke system admin" do
    sign_in_as(@admin, password: "password")

    @regular_user.update!(system_admin: true)

    patch revoke_system_admin_user_path(@regular_user)

    assert_redirected_to users_path
    follow_redirect!
    assert_equal I18n.t("users.system_admin.revoked"), flash[:notice]
    refute @regular_user.reload.system_admin?
  end

  test "system admin cannot delete themselves" do
    sign_in_as(@admin, password: "password")

    assert_no_difference("User.count") do
      delete user_path(@admin)
    end

    assert_redirected_to users_path
    follow_redirect!
    assert_equal I18n.t("users.destroy.cannot_delete_self"), flash[:alert]
  end

  test "system admin can delete a user and all associated data" do
    sign_in_as(@admin, password: "password")

    user_to_delete = @regular_user
    creative = Creative.create!(user: user_to_delete, description: "Test creative")
    comment = Comment.create!(creative: creative, user: user_to_delete, content: "Test comment")
    pointer = CommentReadPointer.create!(user: user_to_delete, creative: creative, last_read_comment: comment)
    expanded_state = CreativeExpandedState.create!(user: user_to_delete, creative: creative, expanded_status: { creative.id => true })
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
    inbox_item = InboxItem.create!(owner: user_to_delete, message_key: "test.key", message_params: {})
    invitation = Invitation.create!(inviter: user_to_delete, creative: creative, permission: :read)
    plan_creative = Creative.create!(user: user_to_delete, description: "Sample Plan")
    plan = Plan.create!(owner: user_to_delete, creative: plan_creative, target_date: Date.current)
    tag = Tag.create!(label: plan, creative_id: creative.id)
    session = user_to_delete.sessions.create!(user_agent: "TestAgent", ip_address: "127.0.0.1")

    fake_calendar_service = Minitest::Mock.new
    fake_calendar_service.expect(:delete_event, true, [ calendar_event.google_event_id ])

    GoogleCalendarService.stub :new, fake_calendar_service do
      assert_difference("User.count", -1) do
        delete user_path(user_to_delete)
      end
    end

    fake_calendar_service.verify

    assert_redirected_to users_path
    follow_redirect!
    assert_equal I18n.t("users.destroy.success"), flash[:notice]

    refute User.exists?(user_to_delete.id)
    refute Creative.exists?(creative.id)
    refute Comment.exists?(comment.id)
    refute CommentReadPointer.exists?(pointer.id)
    refute CreativeExpandedState.exists?(expanded_state.id)
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
      llm_model: "gemini-2.5-flash",
      system_prompt: "You are a bot.",
      created_by_id: @regular_user.id,
      email_verified_at: Time.current
    )

    assert_difference("User.count", -1) do
      delete user_path(ai_user)
    end

    assert_redirected_to user_path(@regular_user, tab: "contacts")
    follow_redirect!
    assert_equal I18n.t("users.destroy.success"), flash[:notice]
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
      llm_model: "gemini-2.5-flash",
      system_prompt: "You are a bot.",
      created_by_id: creator.id,
      email_verified_at: Time.current
    )

    assert_no_difference("User.count") do
      delete user_path(ai_user)
    end

    assert_redirected_to user_path(@regular_user, tab: "contacts")
    follow_redirect!
    assert_equal I18n.t("users.destroy.not_authorized"), flash[:alert]
  end

  test "prepare_contacts includes shares on origin creatives for linked creatives" do
    sign_in_as(@admin, password: "password")

    # Create an origin creative owned by regular_user
    origin_creative = Creative.create!(user: @regular_user, description: "Origin creative")

    # Create a linked creative owned by admin (pointing to origin)
    Creative.create!(
      user: @admin,
      description: "Linked creative",
      origin_id: origin_creative.id
    )

    # Create another user who will be shared with
    shared_user = User.create!(
      email: "shared@example.com",
      password: "password",
      password_confirmation: "password",
      name: "Shared User"
    )

    # Share the origin creative with shared_user (shared_by regular_user)
    CreativeShare.create!(
      creative: origin_creative,
      user: shared_user,
      permission: :feedback,
      shared_by: @regular_user
    )

    # Access the user show page contacts tab to trigger prepare_contacts
    get user_path(@admin, tab: "contacts")
    assert_response :success

    # Verify that shared_user appears in the contacts list
    # This confirms that the admin sees shared_user because they own a linked creative
    # that points to origin_creative, which is shared with shared_user
    assert_includes response.body, shared_user.email,
                    "Admin should see shared_user in contacts because they own a linked creative"
    assert_includes response.body, shared_user.name,
                    "Admin should see shared_user's name in contacts"
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

    get search_users_path, params: { q: "feedback", creative_id: creative.id }
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

    get search_users_path, params: { q: "searchable" }
    assert_response :success
    results = JSON.parse(response.body)

    emails = results.map { |u| u["email"] }
    assert_includes emails, searchable_user.email
    assert_equal 1, results.length
  end

  test "ai user defaults to non-searchable when checkbox is unchecked" do
    sign_in_as(@regular_user, password: "password")

    assert_difference("User.count", 1) do
      post create_ai_users_path, params: {
        ai_id: "nobot",
        name: "No Bot",
        system_prompt: "You are a helpful bot.",
        llm_model: User::SUPPORTED_LLM_MODELS.first
      }
    end

    ai_user = User.find_by(email: "nobot@ai.local")
    assert_not_nil ai_user
    refute ai_user.searchable?

    assert_redirected_to user_path(@regular_user, tab: "contacts")
    follow_redirect!
    assert_equal I18n.t("users.create_ai.success"), flash[:notice]
  end

  test "ai user creator sees delete button in contacts" do
    sign_in_as(@regular_user, password: "password")

    ai_user = User.create!(
      name: "MyBot",
      email: "mybot3@ai.local",
      password: "password",
      llm_vendor: "google",
      llm_model: "gemini-2.5-flash",
      system_prompt: "You are a bot.",
      created_by_id: @regular_user.id,
      email_verified_at: Time.current
    )

    Contact.ensure(user: @regular_user, contact_user: ai_user)

    get user_path(@regular_user, tab: "contacts")
    assert_response :success
    assert_includes response.body, I18n.t("users.destroy.delete_ai_user")
    assert_includes response.body, I18n.t("users.destroy.confirm_ai")
  end

  test "non creator does not see delete button for ai user contact" do
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
      llm_model: "gemini-2.5-flash",
      system_prompt: "You are a bot.",
      created_by_id: creator.id,
      email_verified_at: Time.current
    )

    Contact.ensure(user: @regular_user, contact_user: ai_user)

    get user_path(@regular_user, tab: "contacts")
    assert_response :success
    refute_includes response.body, I18n.t("users.destroy.delete_ai_user")
  end
  test "search with scope contacts returns contact users" do
    sign_in_as(@admin, password: "password")

    # @admin (one) has contact @regular_user (two) from fixtures
    get search_users_path, params: { q: "two", scope: "contacts" }
    assert_response :success
    results = JSON.parse(response.body)

    assert_equal 1, results.length
    assert_equal @regular_user.email, results.first["email"]
  end

  test "search with scope contacts allows empty query" do
    sign_in_as(@admin, password: "password")

    get search_users_path, params: { q: "", scope: "contacts" }
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

    get search_users_path, params: { q: "", scope: "contacts", limit: 10 }
    assert_response :success
    results = JSON.parse(response.body)
    assert_equal 10, results.length

    # Default limit 20
    get search_users_path, params: { q: "", scope: "contacts" }
    results = JSON.parse(response.body)
    assert_equal 20, results.length
  end

  test "search returns correct json structure" do
    sign_in_as(@admin, password: "password")

    get search_users_path, params: { q: "two", scope: "contacts" }
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

    get passkeys_user_path(other_user)

    assert_redirected_to user_path(@regular_user)
    assert_equal I18n.t("users.destroy.not_authorized"), flash[:alert]
  end

  test "user can access their own passkeys page" do
    sign_in_as(@regular_user, password: "password")

    get passkeys_user_path(@regular_user)
    assert_response :success
  end

  test "system admin can access other user's passkeys page" do
    sign_in_as(@admin, password: "password")

    get passkeys_user_path(@regular_user)
    assert_response :success
  end
  test "admin link appears in profile for system admin" do
    sign_in_as(@admin, password: "password")
    get user_path(@admin)
    assert_response :success
    assert_select "a[href=?]", admin_path
  end

  test "admin link does not appear in profile for regular user" do
    sign_in_as(@regular_user, password: "password")
    get user_path(@regular_user)
    assert_response :success
    assert_select "a[href=?]", admin_path, count: 0
  end
end
