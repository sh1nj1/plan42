# frozen_string_literal: true

namespace :collavre do
  namespace :inbox do
    desc "Create inbox creatives for existing users who don't have one"
    task backfill: :environment do
      user_class = Collavre.user_class
      total = user_class.count
      created = 0
      skipped = 0
      processed = 0

      puts "Processing #{total} users..."

      user_class.find_each do |user|
        processed += 1
        if user.ai_user?
          skipped += 1
          next
        end

        if Collavre::Creative.where(user: user).inboxes.exists?
          skipped += 1
        else
          Collavre::Creative.inbox_for(user)
          created += 1
          print "\r[#{processed}/#{total}] Created: #{created}, Skipped: #{skipped}"
        end
      rescue StandardError => e
        puts "\nFailed for user #{user.id}: #{e.message}"
      end

      puts "\nDone. Created: #{created}, Skipped: #{skipped}"
    end
  end
end
