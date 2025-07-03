class Plan < Label
  validates :target_date, presence: true

  def progress(user = Current.user)
    roots = Creative.where(user: user).roots
    values = roots.map { |c| c.progress_for_tags(id, user) }.compact
    return 0 if values.empty?

    values.sum.to_f / values.size
  end
end
