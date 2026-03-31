require "set"

module Collavre
  class Plan < Label
    validates :target_date, presence: true
    validate :start_date_not_after_target_date

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

    # Delegate start_date to the associated creative's created_at
    def start_date
      creative&.created_at&.to_date
    end

    def start_date=(value)
      return unless creative

      date = value.is_a?(Date) ? value : Date.parse(value.to_s)
      creative.update_column(:created_at, date.to_datetime)
    end

    private

    def start_date_not_after_target_date
      return if start_date.blank? || target_date.blank?

      return unless start_date > target_date

      errors.add(:start_date, "must be on or before target date")
    end
  end
end
