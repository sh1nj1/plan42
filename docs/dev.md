
# FAQ

### 개발시 CSS 수정후 즉시 반영 안됨

아래와 같이 해야 반영 되는 문제가 있었음

* `rails assets:precompile`
* restart server

해결:

* `rm -rf public/assets`

### open prod console

`kamal app exec -i ./bin/rails console`

### show docker volume path

`docker volume inspect plan42_storage`

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

### Change to STI(Single Table Inheritance)

아래 문제에 따라 STI 형태로 Taggable 을 변경

Query:

현재 taggable 에는 Plan, Variation 이 있는데, 이 모든 건 Tag 라는 개념인데, 여러 태그로 검색하기 위해서는 Creative 를 taggable_id 로만 검색할수 없고 또한 해당 아이디는 중복이 될 수 있어. 효율적으로 모든 태그들을 검색하려면, taggable_id 하나로 하는 것이 좋을 것 같아. 따라서 taggable 을 여러 타입의 모델로 만들지 않고 그냥 Label 이라는 하나의 모델로 Plan, Variation, Label 을 표현하고, Label 에 type 컬럼을 둬서 Plan 인지 Variation 인지 Label 인지 구분하는 것이 어떨까? 이때 안좋은 점은 Plan 에는 target_date 필요하지만, 다른 Label 에는 필요하지 않다는 거야.
만약 현재 방식으로 taggable 을 유지 한다면, taggable_id 를 중복되지 않도록 uuid 방식으로 해야 할 것 같아

Answer:

좋은 고민입니다! 두 가지 방식(통합 Label 모델 vs. 기존 Polymorphic Taggable + UUID)에 대한 장단점을 간결하게 정리해드릴게요.

1. Label 모델 단일화(type 컬럼 사용)
   구현: Plan, Variation, Label을 모두 Label 모델(type 컬럼으로 구분)로 관리. Tag는 label_id만 참조.
   장점
   태그 검색이 단일 테이블(label_id)에서 효율적으로 가능 (조인, 인덱스 최적화).
   중복/충돌 없는 키 관리, 단일 테이블 관리로 단순화.
   새로운 타입 추가가 쉬움(type만 추가).
   단점
   Plan에만 필요한 target_date 등, 타입별로 속성이 다를 때 테이블이 비대해짐(NULL 허용 컬럼 많아짐).
   타입별 비즈니스 로직이 복잡해질 수 있음(모델 내 조건 분기 많아짐).
   강한 정합성/제약이 필요한 경우 불편(Plan만의 유효성 등).
2. 기존 Polymorphic Taggable + UUID
   구현: Taggable(Plan, Variation 등) 유지, taggable_id를 UUID로 관리해 중복 방지.
   장점
   각 타입별로 독립적인 관리(Plan만의 컬럼, 유효성, 비즈니스 로직 자유롭게 구현).
   기존 Rails의 polymorphic 관계 활용 가능.
   타입별로 DB 구조가 명확(확장성, 유지보수 용이).
   단점
   태그 검색 시 여러 테이블/타입을 조인하거나 조건 분기 필요(검색 복잡성↑).
   taggable_id가 중복될 수 있으므로, 반드시 UUID로 강제해야 함(마이그레이션 필요).
   타입 추가/변경 시 코드와 DB 양쪽 모두 수정 필요.
   결론 및 추천
   검색 최적화, 단일 관리가 중요하면 Label 단일화(type 컬럼) 모델이 유리합니다.
   타입별 속성/로직이 많이 다르고, 정합성 및 확장성이 중요하면 기존 방식 + UUID가 더 적합합니다.
   참고: Plan의 target_date 같은 필드는
   Label 단일화 모델에서는 target_date를 NULL 허용으로 두거나, 별도 PlanDetail 등으로 분리하는 방법도 있습니다.
   Polymorphic 방식에서는 각 타입별로 자유롭게 속성을 추가할 수 있습니다.

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
* AWS 자격 증명 설정

.env 또는 credentials.yml.enc 등을 사용해서 다음을 설정하세요.

```bash
AWS_SMTP_USERNAME=your-access-key
AWS_SMTP_PASSWORD=your-secret-key
```

.env.ses 파일을 credentials.yml.enc에 추가하여 사용하기

```bash
./bin/migrate_env_to_credentials.rb
```

를 구동하면 credentials.yml.enc 에 추가됨
 
`rails credentials:show` 로 확인 가능

또는 `rails console` 에서 아래 값을 출력해 볼 수 있음.

```ruby
Rails.application.credentials.dig(:aws, :smtp_username)
Rails.application.credentials.dig(:aws, :smtp_password)
Rails.application.credentials.dig(:aws, :region)
```

