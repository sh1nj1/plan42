class InboxSummaryJob < ApplicationJob
  queue_as :default

  def perform
    Rails.logger.info("Running InboxSummaryJob")
    User.find_each do |user|
      if user.notifications_enabled == false
        Rails.logger.info("Skipping inbox summary for #{user.email} because notifications are disabled")
        next
      end

      items = InboxItem.where(owner: user, state: "new").order(created_at: :desc).limit(10)
      if items.empty?
        Rails.logger.info("No new inbox items for #{user.email}")
        next
      end

      Rails.logger.info("Sending inbox summary to #{user.email} with #{items.count} items")
      Collavre::InboxMailer.with(user: user, items: items).daily_summary.deliver_now
    end
  end
end
