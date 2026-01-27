class DeduplicateDeviceFcmTokens < ActiveRecord::Migration[8.0]
  class DeviceRecord < ApplicationRecord
    self.table_name = "devices"
  end

  def up
    DeviceRecord.reset_column_information

    DeviceRecord.group(:fcm_token).having("COUNT(*) > 1").pluck(:fcm_token).each do |token|
      ids = DeviceRecord.where(fcm_token: token).order(updated_at: :desc, id: :desc).pluck(:id)
      duplicate_ids = ids.drop(1)
      next if duplicate_ids.empty?

      DeviceRecord.where(id: duplicate_ids).delete_all
    end

    remove_index :devices, :fcm_token if index_exists?(:devices, :fcm_token)
    add_index :devices, :fcm_token, unique: true
  end

  def down
    remove_index :devices, :fcm_token if index_exists?(:devices, :fcm_token)
    add_index :devices, :fcm_token unless index_exists?(:devices, :fcm_token)
  end
end
