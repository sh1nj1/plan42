# Testing Conventions

## Running Tests

```bash
# All tests (host + engines)
bundle exec rake test

# Single test file
bin/rails test test/controllers/some_test.rb

# Engine tests only
bin/rails test engines/collavre/test/
bin/rails test engines/collavre_notion/test/

# System tests
bin/rails test:system
```

## Test Structure

```
test/                           # Host app tests
engines/collavre/test/          # Core engine tests
engines/collavre_openclaw/test/ # OpenClaw tests
engines/collavre_notion/test/   # Notion tests
```

## Fixtures

Shared fixtures in `test/fixtures/`:
```yaml
# users.yml
one:
  email: user@example.com
  name: Test User
  password_digest: <%= BCrypt::Password.create('password123') %>
```

## Integration Test Helpers

```ruby
class ActionDispatch::IntegrationTest
  include IntegrationAuthHelper

  def sign_in_as(user, password: "password123")
    post session_path, params: { email: user.email, password: password }
  end

  def sign_out
    delete session_path
  end
end
```

## Engine Route Helpers

In engine tests, use explicit route helpers:

```ruby
# Good - explicit engine routes
get main_app.creative_github_integration_path(@creative)
get notion_engine.creative_notion_integration_path(@creative)

# Access helpers
def main_app
  Rails.application.routes.url_helpers
end

def notion_engine
  CollavreNotion::Engine.routes.url_helpers
end
```

## Mocking External Services

```ruby
test "handles external API" do
  mock_response = Minitest::Mock.new
  mock_response.expect :body, { status: "ok" }.to_json
  
  NotionClient.stub :request, mock_response do
    # Test code
  end
end
```

## Parallel Testing

Tests run in parallel by default:
```ruby
class ActiveSupport::TestCase
  parallelize(workers: :number_of_processors)
end
```

## Closure Tree Setup

After fixture loading, rebuild the tree:
```ruby
setup do
  Creative.rebuild! if defined?(Creative)
end
```
