# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

# Create default admin user if it doesn't exist
default_email = ENV.fetch('DEFAULT_USER_EMAIL', 'admin@example.com')

unless User.exists?(email_address: default_email)
  User.create!(
    email_address: default_email,
    password: ENV.fetch('DEFAULT_USER_PASSWORD', 'password123'),
    password_confirmation: ENV.fetch('DEFAULT_USER_PASSWORD', 'password123')
  )
  puts "Created default user with email: #{default_email}"
end
