# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

# Create default admin user if it doesn't exist.
#
# Skipped when the env bootstraps its admin via first-run signup (e.g. desktop):
# seeding a known email/password there would ship a public admin credential that
# is a standing backdoor on every install. Such envs grant system_admin to the
# first registered user instead (see Collavre::UsersController::Registration).
# NB: compare to `true` explicitly — an unset config.x.* key reads back as a
# truthy empty OrderedOptions, so a bare `if` would skip in every env.
default_email = ENV.fetch('DEFAULT_USER_EMAIL', 'admin@example.com')

if Rails.application.config.x.bootstrap_first_admin == true
  puts "Skipping default admin seed (env bootstraps admin via first-run signup)"
elsif !User.exists?(email: default_email)
  User.create!(
    name: ENV.fetch('DEFAULT_USER_NAME', 'Admin'),
    email: default_email,
    password: ENV.fetch('DEFAULT_USER_PASSWORD', 'password123'),
    password_confirmation: ENV.fetch('DEFAULT_USER_PASSWORD', 'password123'),
    email_verified_at: Time.zone.now,
    system_admin: true
  )
  puts "Created default user with email: #{default_email}"
end

# Load engine seeds
Dir[Rails.root.join("engines", "*", "db", "seeds.rb")].each do |seed_file|
  puts "Loading seeds from: #{seed_file}"
  load seed_file
end
