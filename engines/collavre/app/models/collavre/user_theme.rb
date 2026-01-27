module Collavre
  class UserTheme < ApplicationRecord
    self.table_name = "user_themes"

    belongs_to :user, class_name: Collavre.configuration.user_class_name

    validates :name, presence: true
    validates :variables, presence: true
  end
end
