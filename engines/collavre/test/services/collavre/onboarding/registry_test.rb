# frozen_string_literal: true

require "test_helper"

module Collavre
  module Onboarding
    class RegistryTest < ActiveSupport::TestCase
      test "every scenario uses a registered anchor and has both locales" do
        ScenarioRegistry.all.each do |scenario|
          scenario.steps.each do |step|
            assert AnchorRegistry.registered?(step.anchor), step.anchor
            %i[en ko].each do |locale|
              assert I18n.exists?("collavre.onboarding.steps.#{step.key}.title", locale)
              assert I18n.exists?("collavre.onboarding.steps.#{step.key}.body", locale)
            end
          end
        end
      end
    end
  end
end
