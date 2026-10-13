# Testing Conventions

Automated-test conventions for contributors. For **manual** QA of the live site
(test accounts, credentials), see [test.md](test.md).

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

> **Note:** `rake test` runs the host app plus every engine. Plain `rails test`
> runs the host app only, and `rails test engines/` runs the engines. Run engine
> tests from the **host root**, not from inside the engine directory, or the load
> path resolves incorrectly.

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

`rake test` runs ordinary tests in one parallel process and then runs
`EngineOverrideTest` in a separate serial process. Its `parallelize(workers: 1)`
changes the process-wide Minitest executor, so loading it with the ordinary
suite would disable parallel execution for every test. Use `rake test` for the
complete suite; directly selecting directories containing that file is serial.

Tests run in parallel by default:
```ruby
class ActiveSupport::TestCase
  parallelize(workers: :number_of_processors)
end
```

## Closure Tree Setup

`creative_hierarchies.yml` loads the closure rows alongside `creatives.yml`,
so common setup does not rebuild the tree for every test. The host fixture
directory is a symlink to the core engine fixtures. When changing the Creative
fixture tree, update its closure rows too: include every self row at generation
zero and every ancestor row with its distance to the descendant.
Transactional tests restore these rows on rollback; nontransactional tests
reload them through Rails fixture loading. Tests that bypass model callbacks
when changing parent IDs must rebuild the tree explicitly.
