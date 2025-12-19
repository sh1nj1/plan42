
# FAQ

### CSS changes are not reflected immediately during development

We encountered a situation where updates only appeared after running the following commands:

* `rails assets:precompile`
* restart server

Resolution:

* `rm -rf public/assets`

### open prod console

`kamal app exec -i ./bin/rails console`

### show docker volume path

`docker volume inspect plan42_storage`

### ActionCable single WebSocket usage

Use the singleton consumer in `app/javascript/services/cable.js` to keep a single WebSocket
connection per browser session. Create subscriptions with `createSubscription(identifier, callbacks)`
and avoid calling `createConsumer()` with arguments after the singleton is initialized, since
those arguments are ignored to prevent extra sockets.
Turbo Streams (inbox updates, chat message delivery, and badge counters) use the same connection
via the global `window.ActionCable.createConsumer` override in `app/javascript/application.js`.

**Troubleshooting Duplicate Connections**:
If you see two WebSocket connections (one for App, one for Turbo), it means Turbo is bypassing the singleton.
This happens because `turbo-rails` imports `ActionCable` directly, ignoring `window` patches when bundled.
**Fix**: Explicitly set the consumer in `cable_config.js` by importing `setConsumer` from Turbo Rails internals
(e.g. `../../node_modules/@hotwired/turbo-rails/.../cable.js`) and injecting the singleton.

### send data to javascript

Pass Translations via Data Attributes (Recommended for External JS Files)

If your JS is in a separate file (like select_mode.js), you can't use ERB directly. Instead, pass the translation from your view to the DOM, then read it in JS.

Example: In your ERB view:

```erb
<button id="select-btn" data-cancel-text="<%= t('app.cancel_select') %>">...</button>
```

In your JS:

```javascript
const selectBtn = document.getElementById('select-btn');
selectBtn.textContent = selectBtn.dataset.cancelText;
```

### Change to STI (Single Table Inheritance)

The following question triggered a discussion about converting Taggable to an STI structure.

Query:

> Taggable currently covers Plan and Variation, which are both just types of tags. When I need to search by multiple tags, I can't search Creatives by taggable_id alone, and the IDs can collide. It feels more efficient to manage every tag with a single taggable_id. What if we replace the polymorphic Taggable models with a single Label model that represents Plan, Variation, and Label, using a `type` column to distinguish them? The downside is that only Plan requires `target_date`, while the other labels do not.
>
> If we keep the current polymorphic setup, we would probably need to switch taggable_id to UUIDs to guarantee uniqueness.

Answer:

Great question! Here's a concise comparison between the unified Label model and the existing polymorphic Taggable + UUID approach.

1. Unified Label model (using a `type` column)
   * Implementation: Manage Plan, Variation, and Label within a single Label model (distinguished by the `type` column). Tags reference only `label_id`.
   * Advantages
     * Efficient tag search from one table (`label_id`) with simpler joins and index optimization.
     * Simplified key management with a single table.
     * Adding a new tag type is easy (just add a new `type`).
   * Disadvantages
     * When attributes differ by type (for example, only Plan needs `target_date`), the table grows with many nullable columns.
     * Model logic can get complex due to type-based branching.
     * Enforcing strict integrity per type (like Plan-specific validations) is harder.
2. Existing polymorphic Taggable + UUID
   * Implementation: Keep Taggable (Plan, Variation, etc.) and enforce unique `taggable_id` values via UUIDs.
   * Advantages
     * Each type keeps its own schema, validations, and business rules.
     * Leverages Rails' built-in polymorphic associations.
     * Database structure stays clear per type, making it easier to maintain and extend.
   * Disadvantages
     * Searching tags requires joins or condition branches across multiple tables/types, increasing complexity.
     * `taggable_id` collisions remain possible without UUIDs, so a migration is required to enforce them.
     * Adding or changing types touches both code and database definitions.
   * Recommendation
     * If search optimization and centralized management are the top priorities, the unified Label model is advantageous.
     * If per-type attributes/logic and strong data integrity matter more, keep the existing polymorphic approach with UUIDs.
     * Note: For Plan-only attributes such as `target_date`, the unified model could allow NULL values or move the field to a separate PlanDetail. The polymorphic setup lets each type add attributes freely.

### Setup AWS SES

* create AWS SES and configure it for your domain and add email address for test in sandbox mode.
* create SMTP account. you can use `./bin/setup_ses.rb vrerv.com`
* setup action mailer in `config/environments/production.rb`:
```ruby
config.action_mailer.delivery_method = :smtp
config.action_mailer.smtp_settings = {
  address:              "email-smtp.#{Rails.application.credentials.dig(:aws, :region)}.amazonaws.com",
  port:                 587,
  user_name:            Rails.application.credentials.dig(:aws, :smtp_username),
  password:             Rails.application.credentials.dig(:aws, :smtp_password),
  authentication:       :plain,
  enable_starttls_auto: true,
  debug_output:         $stdout
}
```
* Configure AWS credentials

Use `.env` or `credentials.yml.enc` to set the following values.

```bash
AWS_SMTP_USERNAME=your-access-key
AWS_SMTP_PASSWORD=your-secret-key
```

To load variables from `.env.ses` into `credentials.yml.enc`, run:

```bash
./bin/migrate_env_to_credentials.rb
```

The script writes the values into `credentials.yml.enc`.

Check them with `rails credentials:show`,

or print the values directly from `rails console`.

```ruby
Rails.application.credentials.dig(:aws, :smtp_username)
Rails.application.credentials.dig(:aws, :smtp_password)
Rails.application.credentials.dig(:aws, :region)
```
