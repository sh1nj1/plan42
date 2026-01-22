# Configure Collavre Engine
Collavre.configure do |config|
  # The User model class name
  config.user_class_name = "User"

  # How to get the current user
  config.current_user_method = -> { Current.user }
end
