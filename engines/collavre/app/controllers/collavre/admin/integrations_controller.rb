# frozen_string_literal: true

module Collavre
  module Admin
    class IntegrationsController < ApplicationController
      before_action :require_system_admin!
      before_action :load_definition!, only: [ :reset ]

      Registry = Collavre::IntegrationSettings::Registry
      Resolver = Collavre::IntegrationSettings::Resolver

      def index
        @grouped_settings = build_grouped_settings
      end

      def bulk_update
        submitted = (params[:integration_setting] || {}).to_unsafe_h
        restart_required_changed = false

        Collavre::IntegrationSetting.transaction do
          submitted.each do |key, raw_value|
            value = raw_value.to_s
            next if value.blank?

            definition = Registry.instance.find(key) or next

            row = Collavre::IntegrationSetting.find_or_initialize_by(key: definition.key.to_s)
            row.category = definition.category
            row.value = value
            row.save!

            restart_required_changed ||= definition.requires_restart
          end
        end

        flash[:notice] = t("collavre.admin.integrations.flash.updated")
        flash[:warning] = t("collavre.admin.integrations.flash.restart_required") if restart_required_changed
        redirect_to collavre.admin_integrations_path
      end

      def reset
        Collavre::IntegrationSetting.where(key: @definition.key.to_s).destroy_all
        redirect_to collavre.admin_integrations_path,
          notice: t("collavre.admin.integrations.flash.reset_done", key: @definition.key)
      end

      private

      def load_definition!
        @definition = Registry.instance.find(params[:key]) or
          (render file: Rails.root.join("public/404.html"), status: :not_found, layout: false and return)
      end

      def build_grouped_settings
        Registry.instance.by_category.sort_by { |category, _defs| category.to_s }.map do |category, definitions|
          rows = definitions.map { |definition| build_row(definition) }
          [ category, rows ]
        end
      end

      def build_row(definition)
        value = Resolver.get(definition.key)
        source = Resolver.source_for(definition.key)
        display = definition.sensitive ? mask_value(value) : value

        {
          definition: definition,
          source: source,
          display_value: display,
          present: value.present?
        }
      end

      def mask_value(value)
        return nil if value.blank?
        return "••••" if value.to_s.length <= 4

        "••••#{value.to_s[-4..]}"
      end
    end
  end
end
