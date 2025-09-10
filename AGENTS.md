# Agent Development Guide

## before push codes for PR to confirm no test failures and no offenses
- run `./bin/rubocop -a` every time push codes for PR to confirm code style and no offenses.
- run `rails test`
- run `./bin/bundle exec rspec --exclude-pattern "spec/system/**/*"` 
