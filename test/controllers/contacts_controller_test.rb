require "test_helper"

class ContactsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @contact_user = users(:three)
  end

  test "adds user to contacts by email" do
    sign_in_as(@user, password: "password")

    assert_difference("Contact.count", 1) do
      post contacts_path, params: { contact: { email: @contact_user.email } }
    end

    assert_redirected_to user_path(@user, tab: "contacts")
    follow_redirect!
    assert_equal I18n.t("contacts.notices.added", name: @contact_user.display_name), flash[:notice]
  end

  test "does not add self" do
    sign_in_as(@user, password: "password")

    assert_no_difference("Contact.count") do
      post contacts_path, params: { contact: { email: @user.email } }
    end

    assert_redirected_to user_path(@user, tab: "contacts")
    follow_redirect!
    assert_equal I18n.t("contacts.errors.self_add"), flash[:alert]
  end

  test "removes contact" do
    sign_in_as(@user, password: "password")
    contact = contacts(:one_two)

    assert_difference("Contact.count", -1) do
      delete contact_path(contact), params: { contact_page: 2 }
    end

    assert_redirected_to user_path(@user, tab: "contacts", contact_page: 2)
    follow_redirect!
    assert_equal I18n.t("contacts.notices.removed"), flash[:notice]
  end
end
