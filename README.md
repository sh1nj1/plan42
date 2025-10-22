# Collavre

A tracker of your creatives.

Your creativeness is coming!

* [Features](docs/features.md)

## Getting Started

[Ruby on Rails getting started document](https://github.com/sh1nj1/ror_getting_started/blob/main/getting_started.md)

* `bin/rails credentials:edit` - Create or edit the `config/credentials.yml.enc` file and `config/master.key` file.
* `bin/rails db:prepare` - Run database migrations (default to use sqlite3)
* `bin/rails server` - Start the Rails server. When `SOLID_QUEUE_IN_PUMA` is set, the background job processor and scheduler run alongside the server. The `bin/dev` script sets this variable automatically in development.

### Runtime version info:

```bash
store % ruby -v
ruby 3.4.1 (2024-12-25 revision 48d4efcb85) +PRISM [arm64-darwin24]
store % rails -v
Rails 8.0.2
```

## JavaScript bundling

This project uses `jsbundling-rails`, so Node.js and npm packages must be installed when building for production. Ensure `npm ci`
runs before `rails assets:precompile`. The provided Dockerfile and Render build script handle this automatically.

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
