require "set"

class Plan < Label
  validates :target_date, presence: true

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
end
