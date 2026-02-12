module Collavre
  class UserTheme < ApplicationRecord
    self.table_name = "user_themes"

    belongs_to :user, class_name: Collavre.configuration.user_class_name

    validates :name, presence: true
    validates :variables, presence: true

    # Returns true if the theme has a dark background (lightness < 50%)
    def dark?
      bg = variables["--surface-bg"].to_s
      return false unless bg.match?(/\A#[0-9a-fA-F]{6}\z/)

      r, g, b = bg[1..2].to_i(16), bg[3..4].to_i(16), bg[5..6].to_i(16)
      luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
      luminance < 0.5
    end
  end
end
