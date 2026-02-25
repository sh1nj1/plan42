# frozen_string_literal: true

module Collavre
  class ApiKeysController < ApplicationController
    before_action :set_api_key, only: [ :destroy ]

    def index
      @api_keys = Current.user.api_keys.order(created_at: :desc)
    end

    def create
      api_key, token = ApiKey.create_with_token!(
        user: Current.user,
        name: params[:name].presence || I18n.t("collavre.api_keys.default_name"),
        expires_at: params[:expires_at].present? ? Time.zone.parse(params[:expires_at]) : nil
      )

      render json: {
        id: api_key.id,
        name: api_key.name,
        token: token,
        created_at: api_key.created_at.iso8601,
        message: I18n.t("collavre.api_keys.created")
      }, status: :created
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    def destroy
      @api_key.destroy!
      render json: { message: I18n.t("collavre.api_keys.deleted") }
    end

    private

    def set_api_key
      @api_key = Current.user.api_keys.find(params[:id])
    end
  end
end
