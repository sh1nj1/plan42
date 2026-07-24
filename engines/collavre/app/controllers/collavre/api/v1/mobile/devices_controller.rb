# frozen_string_literal: true

module Collavre
  module Api
    module V1
      module Mobile
        # FCM registration for the Android companion. Push is a follow-up (MVP
        # uses foreground polling), but registering the device now keeps the
        # token current so push can light up without a client change.
        class DevicesController < BaseController
          def create
            device = Collavre::Device.find_by(fcm_token: device_params[:fcm_token]) ||
                     current_user.devices.find_or_initialize_by(client_id: device_params[:client_id])

            device.assign_attributes(device_params)
            device.user = current_user
            device.device_type = :android if device.device_type.blank?
            device.save!
            head :no_content
          end

          private

          def device_params
            params.require(:device).permit(:client_id, :device_type, :app_id, :app_version, :fcm_token)
          end
        end
      end
    end
  end
end
