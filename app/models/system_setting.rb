class SystemSetting < ApplicationRecord
  validates :key, presence: true, uniqueness: true

  def self.help_menu_link
    find_by(key: "help_menu_link")&.value
  end
end
