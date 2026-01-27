module Collavre
  class DevicesController < ApplicationController
    def create
      device = Device.find_by(fcm_token: device_params[:fcm_token]) ||
               Current.user.devices.find_or_initialize_by(client_id: device_params[:client_id])

      device.assign_attributes(device_params)
      device.user = Current.user
      device.save!
      head :no_content
    end

    private

    def device_params
      params.require(:device).permit(:client_id, :device_type, :app_id, :app_version, :fcm_token)
    end
  end
end
