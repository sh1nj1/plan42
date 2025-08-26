# Google Authentication Setup

This application supports signing in with Google using OpenID Connect. It also
requests permission to manage the user's Google Calendar so events can be
created on behalf of the user.

## Configure Google credentials

1. Visit [Google Cloud Console](https://console.cloud.google.com/apis/credentials).
2. Create an OAuth client ID for a **Web application**.
3. Enable the **Google Calendar API** for your project.
4. Add the authorized redirect URI:
   `https://YOUR_DOMAIN/auth/google_oauth2/callback`
5. Note the **Client ID** and **Client Secret**.

Store these values in `config/credentials.yml.enc`:

```yaml
google:
  client_id: YOUR_CLIENT_ID
  client_secret: YOUR_CLIENT_SECRET
```

Run `bin/rails credentials:edit` to add them. The application requests the
`calendar` scope and offline access to obtain a refresh token for API calls.

## Usage

On the sign in or sign up pages click **Sign in with Google**. If an account
with the returned email does not exist, a new user is created automatically with
the email and name from Google. The first time you sign in you will be asked to
authorize calendar access and a refresh token will be stored for future API
requests.
