# frozen_string_literal: true

namespace :encryption do
  desc "Re-encrypt all encrypted attributes with the current primary key"
  task reencrypt: :environment do
    dry_run = ENV["DRY_RUN"].present?
    puts "=== Active Record Encryption Re-encryption ==="
    puts "Mode: #{dry_run ? 'DRY RUN (no changes will be made)' : 'LIVE'}"
    puts

    # Define models and their encrypted attributes
    encrypted_models = {
      "User" => [:llm_api_key]
    }

    total_updated = 0
    total_skipped = 0
    total_errors = 0

    encrypted_models.each do |model_name, attributes|
      model = model_name.constantize
      puts "Processing #{model_name}..."

      attributes.each do |attribute|
        puts "  Attribute: #{attribute}"

        # Find records with non-null encrypted attribute
        records = model.where.not(attribute => nil)
        count = records.count
        puts "  Found #{count} records with #{attribute} set"

        next if count.zero?

        records.find_each.with_index do |record, index|
          print "\r  Processing #{index + 1}/#{count}..."

          begin
            if dry_run
              # In dry run, just verify we can read the value
              record.send(attribute)
              total_skipped += 1
            else
              # Re-encrypt by reading and writing back
              # This forces re-encryption with the current primary key
              record.encrypt
              record.save!(validate: false)
              total_updated += 1
            end
          rescue => e
            total_errors += 1
            puts "\n  ERROR on #{model_name}##{record.id}: #{e.message}"
          end
        end
        puts "\r  Processed #{count} records.#{' ' * 20}"
      end
      puts
    end

    puts "=== Summary ==="
    if dry_run
      puts "Records readable: #{total_skipped}"
      puts "Errors: #{total_errors}"
      puts
      puts "Run without DRY_RUN=1 to perform actual re-encryption."
    else
      puts "Records re-encrypted: #{total_updated}"
      puts "Errors: #{total_errors}"
    end
  end

  desc "Verify all encrypted attributes can be decrypted"
  task verify: :environment do
    puts "=== Verifying Encrypted Attributes ==="
    puts

    encrypted_models = {
      "User" => [:llm_api_key]
    }

    total_ok = 0
    total_errors = 0
    error_details = []

    encrypted_models.each do |model_name, attributes|
      model = model_name.constantize
      puts "Checking #{model_name}..."

      attributes.each do |attribute|
        records = model.where.not(attribute => nil)
        count = records.count
        puts "  #{attribute}: #{count} records"

        records.find_each do |record|
          begin
            record.send(attribute)
            total_ok += 1
          rescue => e
            total_errors += 1
            error_details << "#{model_name}##{record.id}.#{attribute}: #{e.message}"
          end
        end
      end
    end

    puts
    puts "=== Summary ==="
    puts "Readable: #{total_ok}"
    puts "Errors: #{total_errors}"

    if error_details.any?
      puts
      puts "Error details:"
      error_details.each { |detail| puts "  - #{detail}" }
      exit 1
    end
  end
end
