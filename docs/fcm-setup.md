# FCM Integration Setup Guide

This document explains the baseline configuration steps required to send push notifications with Firebase Cloud Messaging (FCM) in Collavre.

## 1. Create a Firebase project

1. Visit the [Firebase Console](https://console.firebase.google.com/) and create a new project.
2. In the project settings, open the **Cloud Messaging** tab and locate the `Server key` and `Sender ID` values.

## 2. Configure the Web Push certificate

1. In the **Cloud Messaging** tab, click **Generate key pair** in the `Web Push certificates` section to issue a VAPID key pair.
2. Store the generated `Public key` so that your frontend application can use it.

## 3. Backend configuration

To enable FCM in the Rails application, run `rails credentials:edit` and add the following values.

```yaml
firebase:
  api_key: your_api_key
  auth_domain: your_auth_domain
  project_id: your_project_id
  app_id: your_app_id
fcm:
  server_key: your_server_key
  sender_id: your_sender_id
  vapid_key: generated_vapid_public_key
```

## 4. Client configuration

To use FCM from the web or a PWA, load the Firebase SDK and initialize the service. For example:

```javascript
import { initializeApp } from "firebase/app";
import { getMessaging, getToken, onMessage } from "firebase/messaging";

const firebaseConfig = window.firebaseConfig;

const app = initializeApp(firebaseConfig);
const messaging = getMessaging(app);

getToken(messaging, { vapidKey: firebaseConfig.vapidKey }).then((currentToken) => {
  if (currentToken) {
    // Send the token to the server
  }
});

onMessage(messaging, (payload) => {
  // Handle foreground messages
});
```

## 5. Send push messages from the server

You can send notifications by using the FCM server key. With the `fcm` gem, send a request like the following:

```ruby
require "fcm"

fcm = FCM.new(Rails.application.credentials.dig(:fcm, :server_key))

response = fcm.send(registration_ids, {
  notification: {
    title: "New notification",
    body: "A new notification just arrived in the Inbox.",
    click_action: "https://your-app.example"
  }
})
```

With this configuration, any Inbox event can trigger an FCM push notification for web or PWA users.

## 6. Device registration and push delivery

Send the FCM token collected in the PWA to the server and persist it as follows.

```javascript
fetch('/devices', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    device: {
      client_id: navigator.userAgent,
      device_type: 'pwa',
      app_id: '<YOUR_APP_ID>',
      app_version: '<APP_VERSION>',
      fcm_token: currentToken
    }
  })
});
```

The server persists the payload in the `devices` table with the following columns:

- `client_id`: An identifier that distinguishes the browser or device.
- `device_type`: One of `web`, `pwa`, `android`, or `ios`.
- `app_id`: The application ID.
- `app_version`: The application version.
- `fcm_token`: The token issued by FCM.

Whenever a new `InboxItem` is created, a push notification is sent to every device registered for that user.

## FCM with AWS Workload Identity Federation

### AWS and GCP Federation Setup

#### Create AWS Role

1. create policy named "AllowSTSForGCPFederation" for Role
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "sts:AssumeRoleWithWebIdentity",
                "sts:GetCallerIdentity"
            ],
            "Resource": "*"
        }
    ]
}
```
2. create a role named "AllowSTSForGCPFederation" with created policy and trusted entity as below
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
```
3. attach role to EC2 instance
    - IAM role name: "AllowSTSForGCPFederation"
    - No need to restart instance, select instance, click Actions > Security > Modify IAM role, select AllowSTSForGCPFederation

### Check EC2 instance IAM role

run this in the EC2 instance

Step-by-Step: Use IMDSv2 from Terminal (Manual Test)
1. Get metadata token
   ```bash
   TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" \
   -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
   ```
2. Use that token to fetch IAM role name
   ```bash
   curl -H "X-aws-ec2-metadata-token: $TOKEN" \
   http://169.254.169.254/latest/meta-data/iam/security-credentials/
   ```
3. Use that token to fetch temporary AWS credentials
   ```bash
   ROLE_NAME=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" \
   http://169.254.169.254/latest/meta-data/iam/security-credentials/)

   curl -H "X-aws-ec2-metadata-token: $TOKEN" \
   http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE_NAME
   ```

Or use ruby script.

```ruby
require 'net/http'
require 'uri'
require 'json'

METADATA_BASE = 'http://169.254.169.254/latest'

def fetch_token
  uri = URI("#{METADATA_BASE}/api/token")
  req = Net::HTTP::Put.new(uri)
  req['X-aws-ec2-metadata-token-ttl-seconds'] = "21600"

  res = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }
  raise "Token fetch failed: #{res.code}" unless res.is_a?(Net::HTTPSuccess)
  res.body
end

def fetch_metadata(path, token)
  uri = URI("#{METADATA_BASE}/meta-data/#{path}")
  req = Net::HTTP::Get.new(uri)
  req['X-aws-ec2-metadata-token'] = token

  res = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }
  raise "Metadata fetch failed: #{res.code}" unless res.is_a?(Net::HTTPSuccess)
  res.body
end

token = fetch_token
role_name = fetch_metadata("iam/security-credentials/", token)
credentials = fetch_metadata("iam/security-credentials/#{role_name}", token)

puts "[INFO] IAM Role: #{role_name}"
puts "[INFO] Temporary Credentials:"
puts JSON.pretty_generate(JSON.parse(credentials))
```

### Configure GCP

```shell
gcloud iam workload-identity-pools create aws-pool \
  --location="global" \
  --display-name="AWS Federation Pool"

gcloud iam workload-identity-pools providers create-aws aws-provider \
  --workload-identity-pool="aws-pool" \
  --account-id="[YOUR_AWS_ACCOUNT_ID]" \
  --location="global" \
  --display-name="AWS EC2 Identity Provider"

gcloud projects describe [PROJECT_ID] --format="value(projectNumber)"

# I guess use by pool strategy is better for not being got error. like aws-pool/* but not sure it works.
# see - https://cloud.google.com/iam/docs/workload-identity-federation-with-other-clouds#console_3
gcloud iam service-accounts add-iam-policy-binding firebase-adminsdk-fbsvc@[PROJECT_ID].iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/[PROJECT_NUMBER]/locations/global/workloadIdentityPools/aws-pool/attribute.aws_role/arn:aws:iam::762305182084:role/AllowSTSForGCPFederation"
```

```shell
gcloud iam workload-identity-pools create-cred-config projects/618782485139/locations/global/workloadIdentityPools/aws-pool/providers/aws-provider \
--service-account=firebase-admin-fbsvc@collavre.iam.gserviceaccount.com --aws --enable-imdsv2 --output-file=output.json
```
