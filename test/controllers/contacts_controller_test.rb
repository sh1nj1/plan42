require "test_helper"

class ContactsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
  end

  test "does not expose contact creation route" do
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/contacts", method: :post)
    end
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
