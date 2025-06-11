class InboxSummaryJob < ApplicationJob
  queue_as :default

  def perform
    User.find_each do |user|
      items = InboxItem.where(owner: user, state: "new").order(created_at: :desc).limit(10)
      next if items.empty?

      InboxMailer.with(user: user, items: items).daily_summary.deliver_now
    end
  end
end
