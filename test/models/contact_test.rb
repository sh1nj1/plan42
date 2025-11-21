require "test_helper"

class ContactTest < ActiveSupport::TestCase
  test "valid contact" do
    contact = Contact.new(user: users(:one), contact_user: users(:three))
    assert contact.valid?
  end

  test "rejects duplicates" do
    contact = Contact.new(user: users(:one), contact_user: users(:two))
    refute contact.valid?
  end

  test "rejects self contact" do
    contact = Contact.new(user: users(:one), contact_user: users(:one))
    refute contact.valid?
  end

  test "ensure helper creates missing record" do
    assert_difference("Contact.count", 1) do
      Contact.ensure(user: users(:two), contact_user: users(:three))
    end

    assert_no_difference("Contact.count") do
      Contact.ensure(user: users(:two), contact_user: users(:three))
    end
  end
end
