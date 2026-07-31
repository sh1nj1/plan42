# frozen_string_literal: true

require "test_helper"

class FcmInitializerTest < ActiveSupport::TestCase
  test "defers database-backed FCM configuration until after initialization" do
    initializer_source = Rails.root.join("config/initializers/fcm.rb").read
    configuration_source = Rails.root.join("config/fcm_configuration.rb").read

    assert_match(
      /Rails\.application\.config\.after_initialize do\s+require Rails\.root\.join\("config\/fcm_configuration"\)\.to_s\s+end/,
      initializer_source
    )
    assert_includes configuration_source, "Collavre::IntegrationSettings, :fetch"
  end
end
