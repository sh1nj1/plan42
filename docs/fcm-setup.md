# FCM 연동 설정 가이드

이 문서는 Collavre에서 Firebase Cloud Messaging(FCM)을 사용하여 푸시 알림을 보내기 위한 기본 설정 방법을 설명합니다.

## 1. Firebase 프로젝트 생성

1. [Firebase 콘솔](https://console.firebase.google.com/)에 접속하여 새 프로젝트를 생성합니다.
2. 프로젝트 설정에서 **Cloud Messaging** 탭을 열어 `서버 키`와 `송신자 ID`(Sender ID)를 확인합니다.

## 2. 웹 푸시 인증서 설정

1. **Cloud Messaging** 탭에서 `웹 푸시 인증서` 섹션의 **키 생성** 버튼을 눌러 VAPID 키 쌍을 발급받습니다.
2. 생성된 `공개 키`를 프론트엔드 애플리케이션에서 사용하도록 저장합니다.

## 3. 백엔드 설정

Rails 애플리케이션에서 FCM을 사용하려면 `rails credentials:edit` 명령어로 다음 값들을 추가합니다.

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

## 4. 클라이언트 설정

웹 또는 PWA에서 FCM을 사용하려면 Firebase SDK를 로드하고 서비스를 초기화해야 합니다. 예시는 다음과 같습니다.

```javascript
import { initializeApp } from "firebase/app";
import { getMessaging, getToken, onMessage } from "firebase/messaging";

const firebaseConfig = window.firebaseConfig;

const app = initializeApp(firebaseConfig);
const messaging = getMessaging(app);

getToken(messaging, { vapidKey: firebaseConfig.vapidKey }).then((currentToken) => {
  if (currentToken) {
    // 서버로 토큰 전송
  }
});

onMessage(messaging, (payload) => {
  // 포그라운드 메시지 처리
});
```

## 5. 서버에서 푸시 메시지 보내기

FCM 서버 키를 사용하여 알림을 전송할 수 있습니다. `fcm` gem을 사용한다면 다음과 같이 요청을 보낼 수 있습니다.

```ruby
require "fcm"

fcm = FCM.new(Rails.application.credentials.dig(:fcm, :server_key))

response = fcm.send(registration_ids, {
  notification: {
    title: "새 알림",
    body: "Inbox에 새로운 알림이 도착했습니다.",
    click_action: "https://your-app.example"
  }
})
```

이렇게 설정하면 Inbox에서 알림이 발생할 때 웹 또는 PWA 사용자에게 FCM을 통해 푸시 메시지를 전달할 수 있습니다.

## 6. 디바이스 등록과 푸시 전송

PWA 앱에서 획득한 FCM 토큰을 다음과 같이 서버로 전송하여 저장합니다.

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

서버는 전달받은 정보를 `devices` 테이블에 저장하며, 컬럼은 다음과 같습니다.

- `client_id`: 브라우저나 디바이스를 구분하기 위한 ID
- `device_type`: `web`, `pwa`, `android`, `ios` 중 하나
- `app_id`: 애플리케이션 ID
- `app_version`: 애플리케이션 버전
- `fcm_token`: FCM에서 발급받은 토큰

새로운 InboxItem이 생성될 때마다 해당 사용자의 모든 디바이스로 푸시 알림이 전송됩니다.
