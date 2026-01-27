# frozen_string_literal: true

module Collavre
  class ActivityLog < ApplicationRecord
    self.table_name = "activity_logs"

    belongs_to :creative, class_name: "Collavre::Creative", optional: true
    belongs_to :user, class_name: Collavre.configuration.user_class_name, optional: true
    belongs_to :comment, class_name: "Collavre::Comment", optional: true

    validates :activity, presence: true
  end
end
