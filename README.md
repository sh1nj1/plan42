# Collavre

A tracker of your creatives.

Your creativeness is coming!

Collavre is an experimental project for small development teams to provide a unified platform for knowledge, task management, and chat communication with AI Agents.
The Creative in Collavre represents a tree-like todo list that can serve as a documentation block, task, or chat.

DEMO: [https://collavre.com](https://collavre.com)

* [Features](docs/features_summary.md)

## Getting Started

[Ruby on Rails getting started document](https://github.com/sh1nj1/ror_getting_started/blob/main/getting_started.md)

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

* There's minitest test `./bin/rails test && ./bin/rails test:system`
* system test with `chrome` driver, `SYSTEM_TEST_DRIVER=chrome ./bin/rails test:system`

## JavaScript bundling

This project uses `jsbundling-rails`, so Node.js and npm packages must be installed when building for production. Ensure `npm ci`
runs before `rails assets:precompile`. The provided Dockerfile and Render build script handle this automatically.

## Customization

Collavre supports extension via Local Engines.
- [Engine Development Guide](docs/engine_development.md)

## Deploy to AWS EC2

- [Deploy to AWS EC2](docs/deploy_to_ec2.md)

## Deploying to Render

This application is configured for deployment on Render. The `bin/render-build.sh` script installs npm packages with `npm ci`
before precompiling assets. To deploy:

1. [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/sh1nj1/ror_getting_started)
2. You'll need to set the following environment variables in Render:
   - `RAILS_MASTER_KEY`: Copy from your local `config/master.key` file
   - `DEFAULT_USER_EMAIL`: Email for the default admin user (e.g., admin@example.com)
   - `DEFAULT_USER_PASSWORD`: Password for the default admin user

   After clicking the deploy button, you'll be prompted to set these environment variables.

3. Click "Apply" to start the deployment

Render will automatically create both the web service and the PostgreSQL database as specified in the `render.yaml` configuration.

## License

Collavre is distributed under the terms of the [GNU Affero General Public License v3.0](LICENSE).
