# frozen_string_literal: true

require_relative "../../test_helper"

class CollavreLinear::EngineAssociationsTest < ActiveSupport::TestCase
  test "Collavre::Creative reflects linear_issue_links association" do
    assoc = Collavre::Creative.reflect_on_association(:linear_issue_links)
    assert_not_nil assoc, "Expected Collavre::Creative to have :linear_issue_links association"
    assert_equal "CollavreLinear::IssueLink", assoc.class_name
  end

  test "Collavre::Creative reflects linear_project_links association" do
    assoc = Collavre::Creative.reflect_on_association(:linear_project_links)
    assert_not_nil assoc, "Expected Collavre::Creative to have :linear_project_links association"
    assert_equal "CollavreLinear::ProjectLink", assoc.class_name
  end

  test "User reflects linear_account association" do
    user_class = Collavre.user_class
    assoc = user_class.reflect_on_association(:linear_account)
    assert_not_nil assoc, "Expected User to have :linear_account association"
    assert_equal "CollavreLinear::Account", assoc.class_name
  end

  test "linear metadata key is protected by reserved_metadata_keys" do
    assert_includes Collavre::Creative.reserved_metadata_keys, "linear",
      "Expected 'linear' to be in reserved_metadata_keys registered by the engine"
  end
end
