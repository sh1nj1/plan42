require "set"

module Collavre
  class Plan < Label
    validates :target_date, presence: true
    validate :start_date_not_after_target_date

    before_validation :set_default_start_date, on: :create

    def progress(_user = nil)
      tagged_ids = Tag.where(label_id: id).pluck(:creative_id)
      return 0 if tagged_ids.empty?

      root_ids = Creative.where(id: tagged_ids).map { |c| c.root.id }.uniq
      roots = Creative.where(id: root_ids)
      tagged_set = tagged_ids.to_set
      values = roots.map { |c| c.progress_for_plan(tagged_set) }.compact
      return 0 if values.empty?

      values.sum.to_f / values.size
    end

    private

    def set_default_start_date
      self.start_date ||= Date.current
    end

    def start_date_not_after_target_date
      return if start_date.blank? || target_date.blank?

      return unless start_date > target_date

      errors.add(:start_date, "must be on or before target date")
    end
  end
end
