# script/verify_oauth.rb
app = Doorkeeper::Application.find_or_create_by!(name: "Verification Client") do |app|
  app.redirect_uri = "urn:ietf:wg:oauth:2.0:oob"
end

puts "\n=== OAuth Verification Setup ==="
puts "Application Created: #{app.name}"
puts "Client ID:     #{app.uid}"
puts "Client Secret: #{app.secret}"
puts "Redirect URI:  #{app.redirect_uri}"
puts "\n=== Step 1: Authorize ==="
puts "Visit this URL in your browser (log in if needed):"
puts "http://localhost:3000/oauth/authorize?client_id=#{app.uid}&redirect_uri=#{app.redirect_uri}&response_type=code&scope=public"
puts "\n=== Step 2: Exchange Code ==="
puts "After authorizing, copy the code and run this command:"
puts "curl -X POST -F 'client_id=#{app.uid}' -F 'client_secret=#{app.secret}' -F 'code=CODE_FROM_BROWSER' -F 'grant_type=authorization_code' -F 'redirect_uri=#{app.redirect_uri}' http://localhost:3000/oauth/token"
puts "\n==============================\n"
