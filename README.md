# MIS2

## Features

* Manage H2 system
* Manage H3 system

* [Base Features](docs/features_summary.md)

### Local Development

* install mise and install ruby
  `mise install`
* install nvm and install node
  `nvm install`
* `bundle install`
* `./bin/rails db:prepare`
* `./bin/rails db:seed`
* `brew install vips` # for image processing (macOS)
* `bin/rails server` - Start the Rails server. When `SOLID_QUEUE_IN_PUMA` is set, the background job processor and scheduler run alongside the server. The `bin/dev` script sets this variable automatically in development.

### Test

* There's minitest test `./bin/rake test && ./bin/rails test:system`
* system test with `chrome` driver, `SYSTEM_TEST_DRIVER=chrome ./bin/rails test:system`

## JavaScript bundling

This project uses `jsbundling-rails`, so Node.js and npm packages must be installed when building for production. Ensure `npm ci`
runs before `rails assets:precompile`. The provided Dockerfile and Render build script handle this automatically.

## Customization

Using Rails Engines.
- [Engine Development Guide](docs/engine_development.md)

## Deploy to AWS EC2

- [Deploy to AWS EC2](docs/deploy_to_ec2.md)
