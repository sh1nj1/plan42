class Plan < Label
  validates :target_date, presence: true
end
