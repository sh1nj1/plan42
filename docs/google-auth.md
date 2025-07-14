# Google Authentication Setup

This application supports signing in with Google using OpenID Connect.

## Configure Google credentials

1. Visit [Google Cloud Console](https://console.cloud.google.com/apis/credentials).
2. Create an OAuth client ID for a **Web application**.
3. Add the authorized redirect URI:
   `https://YOUR_DOMAIN/auth/google_oauth2/callback`
4. Note the **Client ID** and **Client Secret**.

Store these values in `config/credentials.yml.enc`:

```yaml
google:
  client_id: YOUR_CLIENT_ID
  client_secret: YOUR_CLIENT_SECRET
```

Run `bin/rails credentials:edit` to add them.

## Usage

On the sign in or sign up pages click **Sign in with Google**. If an account
with the returned email does not exist, a new user is created automatically with
the email and name from Google.
