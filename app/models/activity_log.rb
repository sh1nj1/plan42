# frozen_string_literal: true

class ActivityLog < ApplicationRecord
  belongs_to :creative, optional: true
  belongs_to :user, optional: true
  belongs_to :comment, optional: true

  validates :activity, presence: true
end
