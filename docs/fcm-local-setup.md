# FCM Local Development Setup Guide

This guide explains how to set up Firebase Cloud Messaging (FCM) push notifications for local development using service account credentials.

## Prerequisites

- A Firebase project (create one at [Firebase Console](https://console.firebase.google.com/))
- Rails application with FCM integration
- Google Cloud SDK (optional, for advanced setup)

## Step 1: Create a Firebase Service Account and Grant Permissions

1. **Go to Firebase Console**
   - Visit [Firebase Console](https://console.firebase.google.com/)
   - Select your project

2. **Navigate to Service Accounts**
   - Click the gear icon ⚙️ next to "Project Overview"
   - Select "Project settings"
   - Click on the "Service accounts" tab

3. **Generate Private Key**
   - You'll see a service account like `firebase-adminsdk-xxxxx@your-project-id.iam.gserviceaccount.com`
   - Click the "Generate new private key" button
   - A warning dialog will appear - click "Generate key"
   - A JSON file will be downloaded to your computer

4. **Save the JSON File**
   - Create a secure directory for credentials:
     ```bash
     mkdir -p ~/.config/firebase
     ```
   - Move the downloaded JSON file:
     ```bash
     mv ~/Downloads/your-project-firebase-adminsdk-*.json ~/.config/firebase/fcm-service-account.json
     ```
   - Set appropriate permissions:
     ```bash
     chmod 600 ~/.config/firebase/fcm-service-account.json
     ```

5. **Grant Required Permissions** (IMPORTANT!)
   The service account needs permissions to send FCM messages:
   
   **Option A: Via Google Cloud Console (Recommended)**
   - Go to [Google Cloud Console](https://console.cloud.google.com)
   - Select your Firebase project
   - Navigate to **IAM & Admin** → **IAM**
   - Find your service account: `firebase-adminsdk-xxxxx@your-project-id.iam.gserviceaccount.com`
   - Click the pencil icon to edit
   - Add these roles:
     - **Firebase Cloud Messaging Admin** (required for sending messages)
     - **Service Account Token Creator** (if using impersonation)
   - Click "Save"
   
   **Option B: Via gcloud CLI**
   ```bash
   # Replace YOUR_PROJECT_ID with your actual project ID
   PROJECT_ID="your-project-id"
   SERVICE_ACCOUNT="firebase-adminsdk-xxxxx@${PROJECT_ID}.iam.gserviceaccount.com"
   
   # Grant Firebase Cloud Messaging Admin role
   gcloud projects add-iam-policy-binding $PROJECT_ID \
       --member="serviceAccount:${SERVICE_ACCOUNT}" \
       --role="roles/firebase.cloudMessaging.admin"
   ```

## Step 2: Set Environment Variables

1. **Create or edit `.env.development.local`** in your Rails project root:
   ```bash
   cd /Users/soonoh/project/soonoh/plan42
   touch .env.development.local
   ```

2. **Add the following environment variables**:
   ```bash
   # Path to your service account JSON file
   GOOGLE_APPLICATION_CREDENTIALS=/Users/your-username/.config/firebase/fcm-service-account.json
   
   # Your Firebase project ID (found in Firebase Console > Project Settings)
   FIREBASE_PROJECT_ID=your-project-id
   
   # Optional: Other Firebase configuration
   FIREBASE_API_KEY=your-api-key
   FIREBASE_AUTH_DOMAIN=your-project-id.firebaseapp.com
   FIREBASE_APP_ID=1:123456789:web:abcdef123456
   FCM_SENDER_ID=123456789
   FCM_VAPID_KEY=your-vapid-public-key
   ```

## Step 3: Get Your Firebase Configuration Values

1. **Get Project ID**
   - Firebase Console → Project Settings → General
   - Look for "Project ID"

2. **Get Web App Configuration**
   - Firebase Console → Project Settings → General
   - Scroll to "Your apps" section
   - If no web app exists, click "Add app" → Web icon
   - Copy the configuration values:
     ```javascript
     const firebaseConfig = {
       apiKey: "...",           // → FIREBASE_API_KEY
       authDomain: "...",       // → FIREBASE_AUTH_DOMAIN
       projectId: "...",        // → FIREBASE_PROJECT_ID
       messagingSenderId: "...", // → FCM_SENDER_ID
       appId: "..."             // → FIREBASE_APP_ID
     };
     ```

3. **Get VAPID Key (for Web Push)**
   - Firebase Console → Project Settings → Cloud Messaging
   - Scroll to "Web configuration" section
   - Under "Web Push certificates", click "Generate key pair" if none exists
   - Copy the "Key pair" value → `FCM_VAPID_KEY`

## Step 4: Verify Your Setup

1. **Check if the JSON file is readable**:
   ```bash
   cat $GOOGLE_APPLICATION_CREDENTIALS | jq '.project_id'
   ```
   Should output your project ID.

2. **Test in Rails console**:
   ```bash
   rails console
   ```
   ```ruby
   # Check if credentials are loaded
   puts ENV['GOOGLE_APPLICATION_CREDENTIALS']
   puts File.exist?(ENV['GOOGLE_APPLICATION_CREDENTIALS'])
   
   # Check if FCM service is initialized
   puts Rails.application.config.x.fcm_service.present?
   puts Rails.application.config.x.fcm_project_id
   ```

3. **Send a test notification**:
   ```ruby
   # In Rails console
   user = User.first
   device = user.devices.where(device_type: 'pwa').first
   
   if device && device.fcm_token.present?
     PushNotificationJob.perform_now(
       user: user,
       title: "Test Notification",
       body: "This is a test from localhost!",
       data: { test: true }
     )
   end
   ```

## Step 5: Troubleshooting

### Common Issues

1. **"Could not load the default credentials"**
   - Ensure the JSON file path is absolute, not relative
   - Check file permissions: `ls -la $GOOGLE_APPLICATION_CREDENTIALS`
   - Verify the JSON file is valid: `jq . $GOOGLE_APPLICATION_CREDENTIALS`

2. **"Permission denied" errors (PERMISSION_DENIED: Permission 'cloudmessaging.messages.create' denied)**
   - This means the service account lacks FCM permissions
   - Follow Step 1.5 above to grant permissions
   - Specifically, you need the "Firebase Cloud Messaging Admin" role
   - After granting permissions, restart your Rails server

3. **"Invalid registration token"**
   - The FCM token might be expired
   - Have the client re-register for push notifications
   - Check device token is saved correctly in the database

### Debug Logging

Add to `config/environments/development.rb`:
```ruby
# Enable Google API client logging
ENV['GOOGLE_API_USE_RAILS_LOGGER'] = 'true'
Google::Apis.logger = Rails.logger
Google::Apis.logger.level = Logger::DEBUG
```

## Security Best Practices

1. **Never commit credentials**
   - `.env.development.local` is already in `.gitignore`
   - Never commit the JSON file to version control

2. **Use different service accounts per environment**
   - Create separate service accounts for development/staging/production
   - Use minimal permissions needed

3. **Rotate keys periodically**
   - Delete old keys in Firebase Console
   - Generate new keys every few months

4. **Store credentials securely**
   - Use encrypted disk volumes
   - Consider using a secrets manager for team development

## Alternative: Using FCM Server Key (Legacy)

If you prefer the simpler legacy approach:

1. Get your FCM Server Key:
   - Firebase Console → Project Settings → Cloud Messaging
   - Copy "Server key" (starts with `AAAA...`)

2. Add to `.env.development.local`:
   ```bash
   FCM_SERVER_KEY=AAAA:your-server-key-here
   ```

Note: This method is deprecated by Google and may stop working in the future.

## Next Steps

1. Register a device token from your PWA/web app
2. Store the token in the `devices` table
3. Send push notifications using `PushNotificationJob`
4. Monitor delivery in Firebase Console → Cloud Messaging

For production deployment on AWS EC2, the application will automatically use Workload Identity Federation instead of the service account JSON.