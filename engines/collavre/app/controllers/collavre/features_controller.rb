# frozen_string_literal: true

module Collavre
  # Public, server-rendered guide pages for the empty-chat feature cards.
  #
  # These double as landing content, so they are readable signed out and share
  # the landing layout/stylesheet. All copy lives in config/locales/features.*.yml
  # under collavre.features.pages.<key>; the registry only supplies which keys
  # exist and in what order.
  class FeaturesController < ApplicationController
    allow_unauthenticated_access
    layout "collavre/landing"

    def index
      @cards = Collavre::FeatureCardRegistry.with_builtin_guide
    end

    def show
      @card = Collavre::FeatureCardRegistry.find(params[:key])
      # An unknown key, or a card documented by a vendor engine elsewhere, has no
      # page here — both are a 404 rather than a blank shell of headings.
      raise ActiveRecord::RecordNotFound unless @card&.builtin_guide?

      @page = self.class.page_content(@card.key)
    end

    # Reads a page's copy out of i18n, normalizing the parts a translator can
    # legitimately omit. Missing translations come back from I18n as a String
    # rather than the Array/Hash shape the view walks, so coerce before render
    # instead of letting the view guard every access.
    def self.page_content(key)
      scope = "collavre.features.pages.#{key}"

      {
        title: I18n.t("#{scope}.title", default: ""),
        tagline: I18n.t("#{scope}.tagline", default: ""),
        meta_description: I18n.t("#{scope}.meta_description", default: ""),
        sections: array_of_hashes(I18n.t("#{scope}.sections", default: [])),
        tips: array_of_strings(I18n.t("#{scope}.tips", default: []))
      }
    end

    def self.array_of_hashes(value)
      return [] unless value.is_a?(Array)

      value.select { |entry| entry.is_a?(Hash) && entry[:body].present? }
    end

    def self.array_of_strings(value)
      return [] unless value.is_a?(Array)

      value.select { |entry| entry.is_a?(String) && entry.present? }
    end

    private_class_method :array_of_hashes, :array_of_strings
  end
end
