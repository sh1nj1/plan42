# frozen_string_literal: true

namespace :collavre_github do
  desc "Import markdown files from mock GitHub server into a creative tree"
  task mock_import: :environment do
    puts "=== GitHub Markdown Mock Import ==="
    puts ""

    # 1. Find or create user
    user = User.first
    abort "No user found. Run db:seed first." unless user
    puts "User: #{user.name} (#{user.email})"

    # 2. Find or create GitHub account (mock)
    account = CollavreGithub::Account.find_or_initialize_by(user: user)
    if account.new_record?
      account.assign_attributes(
        github_uid: "mock-12345",
        login: "dev-user",
        name: "Dev User (Mock)",
        token: "mock-token-#{SecureRandom.hex(10)}"
      )
      account.save!
      puts "Created mock GitHub account: #{account.login}"
    else
      puts "Using existing GitHub account: #{account.login}"
    end

    # 3. Find or create a root creative for the import
    repo_name = ENV.fetch("MOCK_REPO", "dev-user/my-app")
    root = Collavre::Creative.find_by(description: "GitHub Docs")
    unless root
      parent = Collavre::Creative.roots.first
      root = Collavre::Creative.create!(
        description: "GitHub Docs",
        parent: parent,
        user: user
      )
      puts "Created root creative: #{root.id} — 'GitHub Docs'"
    end

    # 4. Clean up existing sync (if re-running)
    existing_link = root.github_repository_links.find_by(
      github_account: account,
      repository_full_name: repo_name
    )
    if existing_link
      puts "Cleaning up existing sync..."
      # Archive old markdown tree
      if existing_link.markdown_root_creative
        existing_link.markdown_root_creative.descendants.each do |c|
          c.destroy if c.data.is_a?(Hash) && c.data.dig("source", "type") == "github_markdown"
        end
        existing_link.markdown_root_creative.destroy
      end
      existing_link.update!(markdown_root_creative_id: nil, last_synced_at: nil)
    end

    # 5. Create or reuse RepositoryLink
    link = root.github_repository_links.find_or_create_by!(
      github_account: account,
      repository_full_name: repo_name
    )
    link.update!(markdown_sync_enabled: true, sync_branch: "main")
    puts "RepositoryLink: #{link.id} — #{repo_name} (markdown_sync: enabled)"

    # 6. Run InitialImportService
    puts ""
    puts "Starting import from mock server..."
    puts "(Make sure mock server is running: bin/rails collavre_github:mock_server)"
    puts ""

    begin
      result = CollavreGithub::MarkdownSync::InitialImportService.new(
        repository_link: link,
        user: user
      ).call

      if result
        puts ""
        puts "✅ Import complete!"
        puts "   Created #{result.size} creatives"
        puts "   Root creative: #{link.reload.markdown_root_creative_id}"
        puts "   Last synced: #{link.last_synced_at}"
        puts ""
        puts "   Open the app and navigate to the 'GitHub Docs' creative to see the tree."
      else
        puts "⚠️  No markdown files found in the repository."
      end
    rescue StandardError => e
      puts "❌ Import failed: #{e.message}"
      puts e.backtrace.first(5).join("\n")
      puts ""
      puts "Is the mock server running? Start it with:"
      puts "  bin/rails collavre_github:mock_server"
    end
  end
end
