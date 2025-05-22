**이 파일을 GitHub에서 읽지 마세요, 가이드는 <https://guides.rubyonrails.org>에 게시됩니다.**

Rails 시작하기
==========================

이 가이드는 Ruby on Rails를 설치하고, 새로운 Rails 애플리케이션을 생성하며, 데이터베이스에 연결하는 방법을 다룹니다. 이 가이드를 읽은 후에는 다음을 알게 될 것입니다:

* Rails를 설치하고, 새로운 Rails 애플리케이션을 생성하며 데이터베이스에 연결하는 방법.
* Rails 애플리케이션의 일반적인 레이아웃.
* MVC(모델, 뷰, 컨트롤러)와 RESTful 디자인의 기본 원칙.
* Rails 애플리케이션의 시작 부분을 빠르게 생성하는 방법.
* Kamal을 사용하여 애플리케이션을 프로덕션에 배포하는 방법.

--------------------------------------------------------------------------------

소개
------------
Rails에 오신 것을 환영합니다! 이 가이드에서는 Rails로 웹 애플리케이션을 구축하는 핵심 개념을 단계별로 안내할 것입니다. 이 가이드를 따라가기 위해 Rails 경험이 필요하지 않습니다. Rails는 Ruby 프로그래밍 언어를 위해 구축된 웹 프레임워크입니다. Rails는 Ruby의 많은 기능을 활용하므로, 이 튜토리얼에서 볼 기본 용어와 어휘를 이해할 수 있도록 Ruby의 기초를 학습하는 것을 **강력히** 권장합니다.

- [공식 Ruby 프로그래밍 언어 웹사이트](https://www.ruby-lang.org/en/documentation/)
- [무료 프로그래밍 도서 목록](https://github.com/EbookFoundation/free-programming-books/blob/main/books/free-programming-books-langs.md#ruby)

Rails 철학
----------------
Rails는 Ruby 프로그래밍 언어로 작성된 웹 애플리케이션 개발 프레임워크입니다. 개발자가 시작하는 데 필요한 것을 추측하여 웹 애플리케이션 프로그래밍을 더 쉽게 만들도록 설계되었습니다. 많은 다른 언어와 프레임워크보다 더 적은 코드로 더 많은 일을 할 수 있게 해줍니다. 경험이 많은 Rails 개발자들은 또한 웹 애플리케이션 개발이 더 재미있어졌다고 보고합니다.

Rails는 의견이 있는 소프트웨어입니다. 모든 일을 수행하는 "최고의" 방법이 있다고 가정하며, 그 방식을 장려하고 경우에 따라 대안을 억제하도록 설계되었습니다. "Rails Way"를 배우면 생산성이 크게 향상될 것입니다. 만약 다른 언어에서의 오래된 습관을 Rails 개발에 그대로 적용하려고 하고, 다른 곳에서 배운 패턴을 사용하려고 한다면, 덜 만족스러운 경험을 할 수 있습니다. Rails 철학에는 두 가지 주요 지침 원칙이 포함됩니다:

* **Don't Repeat Yourself (DRY):** DRY는 소프트웨어 개발의 원칙으로 "시스템 내의 모든 지식은 단일하고 명확하며 권위 있는 표현을 가져야 한다"는 것을 의미합니다. 동일한 정보를 반복해서 작성하지 않음으로써, 우리의 코드는 더 유지보수 가능하고, 확장 가능하며, 버그가 적습니다.
* **Convention Over Configuration:** Rails는 웹 애플리케이션을 만드는 데 최선의 방법에 대해 의견을 가지고 있으며, 무한한 설정 파일을 통해 직접 정의하도록 요구하는 대신 이러한 규약 집합을 기본값으로 사용합니다.

새로운 Rails 애플리케이션 생성
------------------------
우리는 `store`라는 프로젝트를 만들 것입니다 - Rails의 내장 기능 중 몇 가지를 보여주는 단순한 전자 상거래 애플리케이션입니다.

TIP: 달러 기호 `$`로 시작하는 모든 명령어는 터미널에서 실행해야 합니다.

### 사전 요구 사항
이 프로젝트를 진행하기 위해서는 다음이 필요합니다:
* Ruby 3.2 이상
* Rails 8.1.0 이상
* 코드 편집기

Ruby 및/또는 Rails를 설치해야 하는 경우 [Ruby on Rails 설치 가이드](https://guides.rubyonrails.org/install_ruby_on_rails.html)를 참조하세요.

Rails의 올바른 버전이 설치되었는지 확인하려면. 현재 버전을 표시하려면 터미널을 열고 다음을 실행하세요. 버전 번호가 출력되어야 합니다:

```bash
$ rails --version
Rails 8.1.0
```

표시된 버전은 Rails 8.1.0 이상이어야 합니다.

### 첫 번째 Rails 애플리케이션 생성
Rails는 여러 명령어를 제공하여 개발을 쉽게 만듭니다. 모든 명령어를 보려면 `rails --help`를 실행하세요. `rails new`는 새로운 Rails 애플리케이션의 기반을 생성하므로 여기서 시작하겠습니다. `store` 애플리케이션을 만들려면 터미널에서 다음 명령어를 실행하세요:

```bash
$ rails new store
```

NOTE: Rails가 생성하는 애플리케이션을 플래그를 사용하여 사용자 정의할 수 있습니다. 이러한 옵션을 보려면 `rails new --help`를 실행하세요.

새 애플리케이션이 생성되면 해당 디렉토리로 이동하세요:

```bash
$ cd store
```

### 디렉토리 구조
새로운 Rails 애플리케이션에 포함된 파일과 디렉토리를 간단히 살펴보겠습니다. 이 폴더를 코드 편집기에서 열거나 터미널에서 `ls -la`를 실행하여 파일과 디렉토리를 확인할 수 있습니다.

| 파일/폴더 | 목적 |
| ----------- | ------- |
|app/|애플리케이션의 컨트롤러, 모델, 뷰, 헬퍼, 메일러, 잡, 에셋을 포함합니다. **이 가이드의 나머지 부분에서는 주로 이 폴더에 집중할 것입니다.**|
|bin/|애플리케이션을 시작하는 `rails` 스크립트를 포함하며, 애플리케이션을 설정, 업데이트, 배포 또는 실행하는 데 사용하는 다른 스크립트를 포함할 수 있습니다.|
|config/|애플리케이션의 라우트, 데이터베이스 등 설정을 포함합니다. 이는 [Rails 애플리케이션 설정](https://guides.rubyonrails.org/configuring.html)에서 더 자세히 다뤄집니다.|
|config.ru|애플리케이션을 시작하는 데 사용되는 Rack 기반 서버의 [Rack](https://rack.github.io) 설정.|
|db/|현재 데이터베이스 스키마 및 데이터베이스 마이그레이션을 포함합니다.|
|Dockerfile|Docker용 구성 파일.|
|Gemfile<br>Gemfile.lock|Rails 애플리케이션에 필요한 gem 종속성을 지정할 수 있게 해주는 파일입니다. 이 파일들은 [Bundler](https://bundler.io) gem에 의해 사용됩니다.|
|lib/|애플리케이션의 확장된 모듈.|
|log/|애플리케이션 로그 파일.|
|public/|정적 파일 및 컴파일된 에셋을 포함합니다. 애플리케이션이 실행 중일 때 이 디렉토리는 있는 그대로 노출됩니다.|
|Rakefile|명령 줄에서 실행할 수 있는 작업을 찾고 로드하는 파일입니다. 작업 정의는 Rails의 다양한 구성 요소에 걸쳐 정의됩니다. `Rakefile`을 변경하기보다는 애플리케이션의 `lib/tasks` 디렉토리에 파일을 추가하여 자신의 작업을 추가해야 합니다.|
|README.md|애플리케이션에 대한 간단한 사용 설명서입니다. 이 파일을 편집하여 다른 사람들에게 애플리케이션이 무엇을 하는지, 어떻게 설정하는지 등을 알려야 합니다.|
|script/|일회성 또는 일반 목적의 [스크립트](https://github.com/rails/rails/blob/main/railties/lib/rails/generators/rails/script/USAGE) 및 [벤치마크](https://github.com/rails/rails/blob/main/railties/lib/rails/generators/rails/benchmark/USAGE)를 포함합니다.|
|storage/|Disk Service용 SQLite 데이터베이스 및 Active Storage 파일을 포함합니다. 이는 [Active Storage 개요](https://guides.rubyonrails.org/active_storage_overview.html)에서 다룹니다.|
|test/|단위 테스트, 픽스처 및 기타 테스트 도구를 포함합니다. 이는 [Rails 애플리케이션 테스트](https://guides.rubyonrails.org/testing.html)에서 다룹니다.|
|tmp/|임시 파일(예: 캐시 및 pid 파일).|
|vendor/|모든 서드파티 코드를 위한 장소입니다. 일반적인 Rails 애플리케이션에서는 vendored gems가 포함됩니다.|
|.dockerignore|Docker에 복사하지 말아야 할 파일을 지정하는 파일입니다.|
|.gitattributes|Git 리포지토리의 특정 경로에 대한 메타데이터를 정의하는 파일입니다. 이 메타데이터는 Git 및 기타 도구가 동작을 향상시키는 데 사용할 수 있습니다. 자세한 내용은 [gitattributes 문서](https://git-scm.com/docs/gitattributes)를 참조하세요.|
|.git/|Git 리포지토리 파일을 포함합니다.|
|.github/|GitHub 특정 파일을 포함합니다.|
|.gitignore|Git이 무시해야 할 파일(또는 패턴)을 지정하는 파일입니다. 파일 무시에 대한 자세한 내용은 [GitHub - 파일 무시](https://help.github.com/articles/ignoring-files)를 참조하세요.|
|.kamal/|Kamal 비밀 및 배포 후크를 포함합니다.|
|.rubocop.yml|RuboCop 설정을 포함하는 파일입니다.|
|.ruby-version|기본 Ruby 버전을 포함하는 파일입니다.|

### 모델-뷰-컨트롤러 기초
Rails 코드는 모델-뷰-컨트롤러(MVC) 아키텍처를 사용하여 구성됩니다. MVC에서는 대부분의 코드가 다음 세 가지 주요 개념에 위치합니다:

* **모델(Model):** 애플리케이션의 데이터를 관리합니다. 일반적으로 데이터베이스 테이블을 의미합니다.
* **뷰(View):** HTML, JSON, XML 등 다양한 형식으로 응답을 렌더링하는 것을 처리합니다.
* **컨트롤러(Controller):** 사용자 상호작용과 각 요청에 대한 논리를 처리합니다.

<picture class="flowdiagram">
  <source srcset="https://guides.rubyonrails.org/images/getting_started/mvc_architecture_dark.jpg" media="(prefers-color-scheme:dark)">
  <img src="https://guides.rubyonrails.org/images/getting_started/mvc_architecture_light.jpg">
</picture>

이제 MVC의 기본을 이해했으니, Rails에서 어떻게 사용되는지 살펴보겠습니다.

Rails, 안녕하세요!
-------------
간단하게 시작하여 첫 번째로 Rails 서버를 부팅해 봅시다. 터미널에서 `store` 디렉토리 내에서 다음 명령어를 실행하세요:

```bash
$ bin/rails server
```

이렇게 하면 Puma라는 웹 서버가 시작되어 정적 파일과 Rails 애플리케이션을 제공합니다:

```bash
Booting Puma
=> Rails 8.1.0 application starting in development
=> Run `bin/rails server --help` for more startup options
Puma starting in single mode...
* Puma version: 6.4.3 (ruby 3.3.5-p100) ("The Eagle of Durango")
* Min threads: 3
* Max threads: 3
* Environment: development
* PID: 12345
* Listening on http://127.0.0.1:3000
* Listening on http://[::1]:3000
Use Ctrl-C to stop
```

브라우저에서 http://localhost:3000을 열어 Rails 애플리케이션을 확인하세요. 기본 Rails 환영 페이지가 표시됩니다:

![Rails welcome page](https://guides.rubyonrails.org/images/getting_started/rails_welcome.png)

작동합니다! 이 페이지는 새로운 Rails 애플리케이션의 *스모크 테스트*로, 페이지를 제공하기 위해 뒤에서 모든 것이 제대로 작동하고 있음을 확인합니다. 언제든지 터미널에서 `Ctrl-C`를 눌러 Rails 서버를 중지할 수 있습니다.

### 개발 환경에서의 자동 로딩
개발자 행복은 Rails의 핵심 철학 중 하나이며, 이를 실현하는 방법 중 하나가 개발 중 자동 코드 재로딩입니다. Rails 서버를 시작하면 새로운 파일이나 기존 파일의 변경 사항이 감지되어 필요에 따라 자동으로 로드되거나 다시 로드됩니다. 이를 통해 매번 변경 후 Rails 서버를 재시작하지 않고도 빌드에 집중할 수 있습니다. 또한, Rails 애플리케이션에서는 다른 프로그래밍 언어에서 보았을 수 있는 `require` 문을 거의 사용하지 않는 것을 알 수 있습니다. Rails는 명명 규칙을 사용하여 파일을 자동으로 요구하므로 애플리케이션 코드 작성에 집중할 수 있습니다. 자세한 내용은 [상수의 자동 로딩 및 재로딩](https://guides.rubyonrails.org/autoloading_and_reloading_constants.html)을 참조하세요.

데이터베이스 모델 생성
-------------------------
Active Record는 Rails의 특징 중 하나로, 관계형 데이터베이스를 Ruby 코드에 매핑합니다. 데이터베이스와 상호작용하기 위한 구조화된 쿼리 언어(SQL)를 생성하는 데 도움을 주며, 테이블 및 레코드 생성, 업데이트, 삭제 등을 처리합니다. 우리 애플리케이션은 Rails의 기본 설정인 SQLite를 사용하고 있습니다. 이제 간단한 전자 상거래 상점에 제품을 추가하기 위해 데이터베이스 테이블을 추가해 봅시다.

```bash
$ bin/rails generate model creative name:string
```

이 명령어는 Rails에게 데이터베이스에 `name`이라는 문자열 타입의 컬럼을 가진 `creative`라는 모델을 생성하도록 지시합니다. 나중에 다른 컬럼 타입을 추가하는 방법을 배우게 될 것입니다. 터미널에서 다음과 같은 출력이 나타납니다:

```bash
invoke  active_record
create    db/migrate/20240426151900_create_creatives.rb
create    app/models/creative.rb
invoke    test_unit
create      test/models/creative_test.rb
create      test/fixtures/creatives.yml
```

이 명령어는 여러 가지 작업을 수행합니다. 이는:

1. `db/migrate` 폴더에 마이그레이션을 생성합니다.
2.
`t.string :name`은 Rails에게 `creatives` 테이블에 `name`이라는 컬럼을 생성하고 타입을 `string`으로 설정하라고 지시합니다. `t.timestamps`는 모델에 두 개의 컬럼을 정의하는 단축키로, `created_at:datetime`과 `updated_at:datetime`을 의미합니다. 이러한 컬럼들은 대부분의 Rails Active Record 모델에서 볼 수 있으며, 레코드를 생성하거나 업데이트할 때 Active Record에 의해 자동으로 설정됩니다.

### 마이그레이션 실행하기

데이터베이스에 어떤 변경을 할지 정의했으니, 다음 명령어를 사용하여 마이그레이션을 실행하세요:

```bash
$ bin/rails db:migrate
```

이 명령어는 새로운 마이그레이션이 있는지 확인하고 이를 데이터베이스에 적용합니다. 출력은 다음과 같이 보일 것입니다:

```bash
== 20240426151900 CreateCreatives: migrating ===================================
-- create_table(:creatives)
   -> 0.0030s
== 20240426151900 CreateCreatives: migrated (0.0031s) ==========================
```

TIP: 실수를 했다면, `bin/rails db:rollback`을 실행하여 마지막 마이그레이션을 되돌릴 수 있습니다.

### Rails 콘솔

이제 `creatives` 테이블을 생성했으니, Rails에서 이를 조작할 수 있습니다. 이를 위해 *콘솔*이라는 Rails 기능을 사용할 것입니다. 콘솔은 Rails 애플리케이션에서 코드를 테스트할 수 있는 유용한 대화형 도구입니다.

```bash
$ bin/rails console
```

다음과 같은 프롬프트가 표시됩니다:

```irb
Loading development environment (Rails 8.1.0) store(dev)>
```

여기서 `Enter`를 누를 때마다 실행될 코드를 입력할 수 있습니다. Rails 버전을 출력해 보겠습니다:

```irb
store(dev)> Rails.version
=> "8.1.0"
```

잘 작동합니다!

### Active Record 모델 기본 사항

Rails 모델 생성기를 사용하여 `creative` 모델을 생성했을 때, `app/models/creative.rb` 파일이 생성되었습니다. 이 파일은 Active Record를 사용하여 우리의 `creatives` 데이터베이스 테이블과 상호 작용하는 클래스를 만듭니다.

```ruby
class creative < ApplicationRecord
end
```

이 클래스에 코드가 없는 것을 보고 놀랄 수도 있습니다. Rails는 이 모델을 어떻게 정의할까요? `creative` 모델이 사용될 때, Rails는 데이터베이스 테이블의 컬럼 이름과 타입을 조회하여 이러한 속성들에 대한 코드를 자동으로 생성합니다. Rails는 이러한 보일러플레이트 코드를 작성하지 않도록 도와주며, 대신 애플리케이션 로직에 집중할 수 있도록 배후에서 이를 처리합니다.

Rails 콘솔을 사용하여 creative 모델이 감지한 컬럼을 확인해 보겠습니다. 다음을 실행하세요:

```irb
store(dev)> creative.column_names
```

다음과 같은 결과를 볼 수 있습니다:

```irb
=> ["id", "name", "created_at", "updated_at"]
```

Rails는 데이터베이스에 컬럼 정보를 요청하고 이를 사용하여 `creative` 클래스에 속성을 동적으로 정의합니다. 이는 Rails가 개발을 얼마나 수월하게 만드는지 보여주는 한 예입니다.

### 레코드 생성하기

다음 코드를 사용하여 새로운 creative 레코드를 인스턴스화할 수 있습니다:

```irb
store(dev)> creative = creative.new(name: "T-Shirt")
=> #<creative:0x000000012e616c30 id: nil, name: "T-Shirt", created_at: nil, updated_at: nil>
```

`creative` 변수는 `creative`의 인스턴스입니다. 데이터베이스에 저장되지 않았기 때문에 ID, created_at, updated_at 타임스탬프가 없습니다. `save`를 호출하여 레코드를 데이터베이스에 저장할 수 있습니다.

```irb
store(dev)> creative.save
```

출력은 다음과 같습니다:

```irb
TRANSACTION (0.1ms) BEGIN IMMEDIATE TRANSACTION /*application='Store'*/
creative Create (0.9ms) INSERT INTO "creatives" ("name", "created_at", "updated_at") VALUES ('T-Shirt', '2024-11-09 16:35:01.117836', '2024-11-09 16:35:01.117836') RETURNING "id" /*application='Store'*/
TRANSACTION (0.9ms) COMMIT TRANSACTION /*application='Store'*/
=> true
```

`save`가 호출되면, Rails는 메모리에 있는 속성을 사용하여 데이터베이스에 이 레코드를 삽입하는 `INSERT` SQL 쿼리를 생성합니다. 또한, 데이터베이스 레코드의 `id`와 `created_at`, `updated_at` 타임스탬프를 메모리의 객체에 업데이트합니다. 이를 확인하기 위해 `creative` 변수를 출력해 봅니다.

```irb
store(dev)> creative
=> #<creative:0x00000001221f6260 id: 1, name: "T-Shirt", created_at: "2024-11-09 16:35:01.117836000 +0000", updated_at: "2024-11-09 16:35:01.117836000 +0000">
```

`save`와 유사하게, `create`를 사용하여 Active Record 객체를 인스턴스화하고 저장할 수 있습니다.

```irb
store(dev)> creative.create(name: "Pants")
TRANSACTION (0.1ms) BEGIN IMMEDIATE TRANSACTION /*application='Store'*/
creative Create (0.4ms) INSERT INTO "creatives" ("name", "created_at", "updated_at") VALUES ('Pants', '2024-11-09 16:36:01.856751', '2024-11-09 16:36:01.856751') RETURNING "id" /*application='Store'*/
TRANSACTION (0.1ms) COMMIT TRANSACTION /*application='Store'*/
=> #<creative:0x0000000120485c80 id: 2, name: "Pants", created_at: "2024-11-09 16:36:01.856751000 +0000", updated_at: "2024-11-09 16:36:01.856751000 +0000">
```

### 레코드 조회하기

Active Record 모델을 사용하여 데이터베이스에서 레코드를 조회할 수도 있습니다. 데이터베이스의 모든 creative 레코드를 찾으려면 `all` 메서드를 사용할 수 있습니다. 이는 클래스 메서드로, `creative`에 사용할 수 있습니다 (`save`와 같은 인스턴스 메서드와 대조).

```irb
store(dev)> creative.all
```

출력은 다음과 같습니다:

```irb
creative Load (0.1ms) SELECT "creatives".* FROM "creatives" /* loading for pp */ LIMIT 11 /*application='Store'*/
=> [#<creative:0x0000000121845158 id: 1, name: "T-Shirt", created_at: "2024-11-09 16:35:01.117836000 +0000", updated_at: "2024-11-09 16:35:01.117836000 +0000">, #<creative:0x0000000121845018 id: 2, name: "Pants", created_at: "2024-11-09 16:36:01.856751000 +0000", updated_at: "2024-11-09 16:36:01.856751000 +0000">]
```

이는 `SELECT` SQL 쿼리를 생성하여 `creatives` 테이블의 모든 레코드를 로드합니다. 각 레코드는 Ruby에서 쉽게 작업할 수 있도록 우리의 `creative` Active Record 모델의 인스턴스로 자동 변환됩니다.

TIP: `all` 메서드는 `ActiveRecord::Relation` 객체를 반환합니다. 이는 필터링, 정렬 및 기타 데이터베이스 작업을 실행할 수 있는 배열과 유사한 컬렉션입니다.

### 레코드 필터링 및 정렬

데이터베이스에서 결과를 필터링하고 싶다면, `where`를 사용하여 컬럼으로 레코드를 필터링할 수 있습니다.

```irb
store(dev)> creative.where(name: "Pants")
```

출력은 다음과 같습니다:

```irb
creative Load (1.5ms) SELECT "creatives".* FROM "creatives" WHERE "creatives"."name" = 'Pants' /* loading for pp */ LIMIT 11 /*application='Store'*/
=> [#<creative:0x000000012184d858 id: 2, name: "Pants", created_at: "2024-11-09 16:36:01.856751000 +0000", updated_at: "2024-11-09 16:36:01.856751000 +0000">]
```

이는 `SELECT` SQL 쿼리를 생성하지만, `WHERE` 절을 추가하여 `name`이 `"Pants"`와 일치하는 레코드만 필터링합니다. 이는 동일한 이름을 가진 여러 레코드가 있을 수 있기 때문에 `ActiveRecord::Relation`을 반환합니다.

이름을 기준으로 오름차순으로 정렬하려면 `order(name: :asc)`를 사용할 수 있습니다.

```irb
store(dev)> creative.order(name: :asc)
```

출력은 다음과 같습니다:

```irb
creative Load (0.3ms) SELECT "creatives".* FROM "creatives" /* loading for pp */ ORDER BY "creatives"."name" ASC LIMIT 11 /*application='Store'*/
=> [#<creative:0x0000000120e02a88 id: 2, name: "Pants", created_at: "2024-11-09 16:36:01.856751000 +0000", updated_at: "2024-11-09 16:36:01.856751000 +0000">, #<creative:0x0000000120e02948 id: 1, name: "T-Shirt", created_at: "2024-11-09 16:35:01.117836000 +0000", updated_at: "2024-11-09 16:35:01.117836000 +0000">]
```

### 레코드 찾기

특정 레코드를 찾고 싶다면, `find` 클래스 메서드를 사용하여 ID로 단일 레코드를 조회할 수 있습니다. 다음과 같이 특정 ID를 전달하여 메서드를 호출하세요:

```irb
store(dev)> creative.find(1)
```

출력은 다음과 같습니다:

```irb
creative Load (0.2ms) SELECT "creatives".* FROM "creatives" WHERE "creatives"."id" = 1 LIMIT 1 /*application='Store'*/
=> #<creative:0x000000012054af08 id: 1, name: "T-Shirt", created_at: "2024-11-09 16:35:01.117836000 +0000", updated_at: "2024-11-09 16:35:01.117836000 +0000">
```

이는 `SELECT` 쿼리를 생성하지만, 전달된 ID가 `1`인 `id` 컬럼에 대한 `WHERE` 절을 지정합니다. 또한, 단일 레코드만 반환하도록 `LIMIT`을 추가합니다. 이번에는 데이터베이스에서 단일 레코드를 조회하기 때문에 `ActiveRecord::Relation` 대신 `creative` 인스턴스를 받습니다.

### 레코드 업데이트

레코드는 `update`를 사용하거나 속성을 할당하고 `save`를 호출하는 두 가지 방법으로 업데이트할 수 있습니다. `creative` 인스턴스에서 `update`를 호출하고 새 속성의 Hash를 전달하여 데이터베이스에 변경 사항을 저장할 수 있습니다. 이는 속성을 할당하고, 검증을 수행하며, 변경 사항을 데이터베이스에 저장하는 한 번의 메서드 호출로 수행됩니다.

```irb
store(dev)> creative = creative.find(1)
store(dev)> creative.update(name: "Shoes")
TRANSACTION (0.1ms) BEGIN IMMEDIATE TRANSACTION /*application='Store'*/
creative Update (0.3ms) UPDATE "creatives" SET "name" = 'Shoes', "updated_at" = '2024-11-09 22:38:19.638912' WHERE "creatives"."id" = 1 /*application='Store'*/
TRANSACTION (0.4ms) COMMIT TRANSACTION /*application='Store'*/
=> true
```

이는 데이터베이스에서 "T-Shirt" 제품의 이름을 "Shoes"로 업데이트했습니다. 이를 확인하기 위해 다시 `creative.all`을 실행하세요.

```irb
store(dev)> creative.all
```

두 개의 제품, 즉 "Shoes"와 "Pants"가 표시됩니다.

```irb
creative Load (0.3ms) SELECT "creatives".* FROM "creatives" /* loading for pp */ LIMIT 11 /*application='Store'*/
=> [#<creative:0x000000012c0f7300 id: 1, name: "Shoes", created_at: "2024-12-02 20:29:56.303546000 +0000", updated_at: "2024-12-02 20:30:14.127456000 +0000">, #<creative:0x000000012c0f71c0 id: 2, name: "Pants", created_at: "2024-12-02 20:30:02.997261000 +0000", updated_at: "2024-12-02 20:30:02.997261000 +0000">]
```

또는 속성을 할당하고 `save`를 호출하여 데이터베이스에 변경 사항을 검증하고 저장할 수 있습니다. "Shoes"의 이름을 다시 "T-Shirt"로 변경해 보겠습니다.

```irb
store(dev)> creative = creative.find(1)
store(dev)> creative.name = "T-Shirt"
=> "T-Shirt"
store(dev)> creative.save
TRANSACTION (0.1ms) BEGIN IMMEDIATE TRANSACTION /*application='Store'*/
creative Update (0.2ms) UPDATE "creatives" SET "name" = 'T-Shirt', "updated_at" = '2024-11-09 22:39:09.693548' WHERE "creatives"."id" = 1 /*application='Store'*/
TRANSACTION (0.0ms) COMMIT TRANSACTION /*application='Store'*/
=> true
```

### 레코드 삭제

`destroy` 메서드를 사용하여 데이터베이스에서 레코드를 삭제할 수 있습니다.

```irb
store(dev)> creative.destroy
TRANSACTION (0.1ms) BEGIN IMMEDIATE TRANSACTION /*application='Store'*/
creative Destroy (0.4ms) DELETE FROM "creatives" WHERE "creatives"."id" = 1 /*application='Store'*/
TRANSACTION (0.1ms) COMMIT TRANSACTION /*application='Store'*/
=> #<creative:0x0000000125813d48 id: 1, name: "T-Shirt", created_at: "2024-11-09 22:39:38.498730000 +0000", updated_at: "2024-11-09 22:39:38.498730000 +0000
데이터베이스에 입력되는 내용이 특정 규칙을 준수해야 합니다. 모든 제품에 `name`이 반드시 존재하도록 creative 모델에 `presence` 검증을 추가해 봅시다.

```ruby
class creative < ApplicationRecord
  validates :name, presence: true
end
```

개발 중에 Rails가 자동으로 변경 사항을 리로드한다는 것을 기억할 겁니다. 그러나 코드에 업데이트를 할 때 콘솔이 실행 중이라면, 수동으로 새로 고쳐야 합니다. 이제 'reload!'를 실행하여 이를 수행해 봅시다.

```irb
store(dev)> reload!
Reloading...
```

Rails 콘솔에서 이름 없이 제품을 생성해 보겠습니다.

```irb
store(dev)> creative = creative.new
store(dev)> creative.save
=> false
```

이번에는 `save`가 `false`를 반환합니다. 이는 `name` 속성이 지정되지 않았기 때문입니다. Rails는 생성, 업데이트 및 저장 작업 중에 자동으로 검증을 실행하여 유효한 입력을 보장합니다. 검증에 의해 생성된 오류 목록을 보려면 인스턴스에서 `errors`를 호출할 수 있습니다.

```irb
store(dev)> creative.errors
=> #<ActiveModel::Errors [#<ActiveModel::Error attribute=name, type=blank, options={}>]>
```

이는 `ActiveModel::Errors` 객체를 반환하여 현재 어떤 오류가 있는지 정확히 알려줍니다. 또한 사용자 인터페이스에서 사용할 수 있는 친근한 오류 메시지를 생성할 수도 있습니다.

```irb
store(dev)> creative.errors.full_messages
=> ["Name can't be blank"]
```

이제 제품을 위한 웹 인터페이스를 구축해봅시다. 현재는 콘솔 사용을 마쳤으니 `exit`을 실행하여 콘솔을 종료할 수 있습니다.

### Rails를 통한 요청 처리 과정

Rails에서 "Hello"를 출력하기 위해서는 최소한 _라우트_, _컨트롤러_와 _액션_, 그리고 _뷰_를 생성해야 합니다. 라우트는 요청을 컨트롤러 액션에 매핑합니다. 컨트롤러 액션은 요청을 처리하는 데 필요한 작업
<h1>creatives#index</h1>
<p>app/views/creatives/index.html.erb에서 찾을 수 있습니다.</p>

```ruby
### Making Requests
```

요청을 살펴보겠습니다. 먼저, 터미널에서 `bin/rails server`를 실행하여 Rails 서버를 시작합니다. 그런 다음 브라우저에서 http://localhost:3000을 열면 Rails 환영 페이지가 표시됩니다. 브라우저에서 http://localhost:3000/creatives을 열면 Rails가 제품 인덱스 HTML을 렌더링합니다. 브라우저는 `/creatives`을 요청했고, Rails는 이 라우트를 `creatives#index`에 매칭했습니다. Rails는 요청을 `CreativesController`로 보내고 `index` 액션을 호출했습니다. 이 액션이 비어 있기 때문에 Rails는 `app/views/creatives/index.html.erb`에 있는 일치하는 템플릿을 렌더링하여 브라우저에 반환했습니다. 꽤 멋지죠!

`config/routes.rb` 파일을 열어보면 다음과 같이 추가할 수 있습니다:

```ruby
root "creatives#index"
```

이제 http://localhost:3000을 방문하면 Rails는 creatives#index를 렌더링합니다.

### 인스턴스 변수

한 걸음 더 나아가 데이터베이스에서 일부 레코드를 렌더링해 보겠습니다. `index` 액션에서 데이터베이스 쿼리를 추가하고 이를 인스턴스 변수에 할당해 봅시다. Rails는 인스턴스 변수(`@`로 시작하는 변수)를 사용하여 데이터를 뷰와 공유합니다.

```ruby
class CreativesController < ApplicationController
  def index
    @creatives = creative.all
  end
end
```

`app/views/creatives/index.html.erb`에서 HTML을 다음 ERB로 대체할 수 있습니다:

```erb
<%= debug @creatives %>
```

ERB는 [Embedded Ruby](https://docs.ruby-lang.org/en/master/ERB.html)의 약자로, Ruby 코드를 실행하여 Rails와 함께 동적으로 HTML을 생성할 수 있게 해줍니다. `<%= %>` 태그는 ERB에게 내부의 Ruby 코드를 실행하고 반환값을 출력하도록 지시합니다. 이 경우, 이는 `@creatives`를 YAML로 변환하여 출력합니다. 브라우저에서 http://localhost:3000/을 새로 고치면 출력이 변경된 것을 볼 수 있습니다. 보시는 것은 데이터베이스에 있는 레코드가 YAML 형식으로 표시된 것입니다. `debug` 헬퍼는 디버깅을 돕기 위해 변수를 YAML 형식으로 출력합니다. 예를 들어, 

만약 주의를 기울이지 않고 단수형 `@creative`를 입력했다면, debug 헬퍼는 컨트롤러에서 변수가 올바르게 설정되지 않았음을 식별하는 데 도움이 될 수 있습니다.

TIP: 사용할 수 있는 더 많은 헬퍼를 보려면 [Action View Helpers 가이드](https://guides.rubyonrails.org/action_view_helpers.html)를 확인하세요.

`app/views/creatives/index.html.erb`를 업데이트하여 모든 제품 이름을 렌더링해 보겠습니다.

```erb
<h1>creatives</h1>
<div id="creatives">
  <% @creatives.each do |creative| %>
    <div>
      <%= creative.name %>
    </div>
  <% end %>
</div>
```

ERB를 사용하여 이 코드는 `@creatives` `ActiveRecord::Relation` 객체의 각 제품을 반복하고 제품 이름을 포함하는 `<div>` 태그를 렌더링합니다. 이번에는 새로운 ERB 태그를 사용했습니다.

```erb
<% %>
```

이 태그는 Ruby 코드를 평가하지만 반환 값을 출력하지 않습니다. 이는 `@creatives.each`의 출력을 무시하여 HTML에 원하지 않는 배열이 출력되지 않도록 합니다.

### CRUD 액션

개별 제품에 접근할 수 있어야 합니다. 이는 CRUD의 R(Read)입니다. 이미 `resources :creatives` 라우트로 개별 제품에 대한 라우트를 정의했습니다. 이는 `/creatives/:id` 라우트를 생성하여 `creatives#show`로 연결합니다. 이제 `CreativesController`에 해당 액션을 추가하고 호출될 때의 동작을 정의해야 합니다.

### 개별 제품 표시

creatives 컨트롤러를 열고 `show` 액션을 다음과 같이 추가하세요:

```ruby
class CreativesController < ApplicationController
  def index
    @creatives = creative.all
  end

  def show
    @creative = creative.find(params[:id])
  end
end
```

여기서 `show` 액션은 단일 레코드를 데이터베이스에서 로드하므로 *단수* `@creative`를 정의합니다. 반면, `index`에서는 여러 제품을 로드하기 때문에 복수형 `@creatives`를 사용합니다. 데이터베이스를 쿼리하기 위해 `params`를 사용하여 요청 매개변수에 접근합니다. 이 경우, 라우트 `/creatives/:id`에서 `:id`를 사용하고 있습니다. `/creatives/1`을 방문하면 params 해시는 `{id: 1}`을 포함하게 되어, `show` 액션이 `creative.find(1)`을 호출하여 데이터베이스에서 ID가 `1`인 제품을 로드합니다.

다음으로 `show` 액션에 대한 뷰가 필요합니다. Rails 명명 규칙을 따르면, `CreativesController`는 `app/views` 내 `creatives`라는 하위 폴더에 뷰를 기대합니다. `show` 액션은 `app/views/creatives/show.html.erb` 파일을 기대합니다. 에디터에서 해당 파일을 생성하고 다음 내용을 추가하세요:

```erb
<h1><%= @creative.name %></h1>
<%= link_to "Back", creatives_path %>
```

인덱스 페이지에서 각 제품에 대한 상세 페이지로 이동할 수 있도록 링크를 추가하면 유용합니다.

`app/views/creatives/index.html.erb` 뷰를 업데이트하여 새 페이지로의 링크를 추가하고, `show` 액션의 경로에 앵커 태그를 사용하는 방법은 다음과 같습니다.

```erb
#6,8
<h1>creatives</h1>
<div id="creatives">
  <% @creatives.each do |creative| %>
    <div>
      <a href="/creatives/<%= creative.id %>">
        <%= creative.name %>
      </a>
    </div>
  <% end %>
</div>
```

이 페이지를 브라우저에서 새로 고치면 작동하지만, 더 나은 방법이 있습니다. Rails는 경로과 URL을 생성하기 위한 헬퍼 메서드를 제공합니다. `bin/rails routes`를 실행하면 Prefix 열을 확인할 수 있습니다. 이 Prefix는 Ruby 코드로 URL을 생성하는 데 사용할 수 있는 헬퍼와 일치합니다.

```bash
Prefix Verb
URI Pattern Controller#Action
creatives GET /creatives(.:format) creatives#index
creative GET /creatives/:id(.:format) creatives#show
```

이러한 라우트 프리픽스는 다음과 같은 헬퍼를 제공합니다:

* `creatives_path`는 `"/creatives"`를 생성합니다.
* `creatives_url`은 `"http://localhost:3000/creatives"`를 생성합니다.
* `creative_path(1)`은 `"/creatives/1"`을 생성합니다.
* `creative_url(1)`은 `"http://localhost:3000/creatives/1"`을 생성합니다.

`_path`는 현재 도메인에 대한 상대 경로를 반환하며, 브라우저가 이를 이해합니다. `_url`은 프로토콜, 호스트 및 포트를 포함한 전체 URL을 반환합니다. URL 헬퍼는 브라우저 외부에서 볼 이메일을 렌더링할 때 유용합니다. `link_to` 헬퍼와 결합하면 Ruby에서 깔끔하게 앵커 태그를 생성하고 URL 헬퍼를 사용할 수 있습니다. `link_to`는 링크의 표시 콘텐츠(`creative.name`)와 `href` 속성에 연결할 경로 또는 URL(`creative`)을 허용합니다. 이를 사용하여 다음과 같이 리팩토링할 수 있습니다:

```erb
#6
<h1>creatives</h1>
<div id="creatives">
  <% @creatives.each do |creative| %>
    <div>
      <%= link_to creative.name, creative %>
    </div>
  <% end %>
</div>
```

### 제품 생성

지금까지는 Rails 콘솔에서 제품을 생성해야 했지만, 이제 브라우저에서 이를 가능하게 해보겠습니다. 생성(Create)을 위해 두 개의 액션이 필요합니다:

1. 제품 정보를 수집하기 위한 새 제품 폼
2. 제품을 저장하고 오류를 확인하는 컨트롤러의 create 액션

먼저 컨트롤러 액션부터 시작하겠습니다.

```ruby
class CreativesController < ApplicationController
  def index
    @creatives = creative.all
  end

  def show
    @creative = creative.find(params[:id])
  end

  def new
    @creative = creative.new
  end
end
```

`new` 액션은 새 `creative`를 인스턴스화하여 폼 필드를 표시하는 데 사용할 것입니다. `app/views/creatives/index.html.erb`를 업데이트하여 새 액션으로 연결하는 링크를 추가할 수 있습니다.

```erb
#3
<h1>creatives</h1>
<%= link_to "New creative", new_creative_path %>
<div id="creatives">
  <% @creatives.each do |creative| %>
    <div>
      <%= link_to creative.name, creative %>
    </div>
  <% end %>
</div>
```

새 `creative`를 생성하기 위한 폼을 렌더링하기 위해 `app/views/creatives/new.html.erb`를 생성하세요.

```erb
<h1>New creative</h1>
<%= form_with model: @creative do |form| %>
  <div>
    <%= form.label :name %>
    <%= form.text_field :name %>
  </div>
  <div>
    <%= form.submit %>
  </div>
<% end %>
```

이 뷰에서는 Rails의 `form_with` 헬퍼를 사용하여 제품을 생성하기 위한 HTML 폼을 생성하고 있습니다. 이 헬퍼는 CSRF 토큰 처리, 제공된 `model:`을 기반으로 URL 생성, 모델에 맞춘 제출 버튼 텍스트 등을 처리하는 *폼 빌더*를 사용합니다. 브라우저에서 이 페이지를 열고 소스를 보면 폼의 HTML은 다음과 같습니다:

```html
<form action="/creatives" accept-charset="UTF-8" method="post">
  <input
```

폼 빌더는 보안을 위한 CSRF 토큰을 포함하고, UTF-8 지원을 위해 폼을 설정하며, 입력 필드 이름을 설정하고 제출 버튼에 비활성화 상태를 추가했습니다.
`creative` 인스턴스를 폼 빌더에 전달했기 때문에, 이는 자동으로 새 레코드를 생성하기 위한 기본 경로인 `/creatives`로 `POST` 요청을 보내도록 구성된 폼을 생성했습니다. 이를 처리하기 위해 먼저 컨트롤러에서 `create` 액션을 구현해야 합니다.

```ruby
#14-26
class CreativesController < ApplicationController
  def index
    @creatives = creative.all
  end

  def show
    @creative = creative.find(params[:id])
  end

  def new
    @creative = creative.new
  end

  def create
    @creative = creative.new(creative_params)
    if @creative.save
      redirect_to @creative
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def creative_params
    params.expect(creative: [ :name ])
  end
end
```

#### 강력한 파라미터

`create` 액션은 폼에서 제출된 데이터를 처리하지만, 보안을 위해 필터링이 필요합니다. 바로 여기서 `creative_params` 메서드가 중요한 역할을 합니다. `creative_params`에서는 Rails에게 `params`를 검사하고 `:creative`라는 키가 있으며 그 값이 매개변수 배열인지 확인하도록 지시합니다. 제품에 허용된 유일한 매개변수는 `:name`이며, Rails는 다른 모든 매개변수를 무시합니다. 이는 애플리케이션을 해킹하려는 악의적인 사용자로부터 보호해 줍니다.

#### 오류 처리

이제 이러한 매개변수를 새로운 `creative`에 할당했으므로 데이터베이스에 저장을 시도할 수 있습니다.

```ruby
@creative.save
```

`@creative.save`는 Active Record에게 유효성 검사를 실행하고 레코드를 데이터베이스에 저장하도록 지시합니다. `save`가 성공하면 새 제품으로 리다이렉트하고자 합니다. `redirect_to`에 Active Record 객체가 주어지면, Rails는 해당 레코드의 `show` 액션에 대한 경로를 생성합니다.

```ruby
redirect_to @creative
```

`@creative`는 `creative` 인스턴스이기 때문에, Rails는 모델 이름을 복수형으로 변환하고 객체의 ID를 경로에 포함시켜 리다이렉트를 위해 `"/creatives/2"`와 같은 경로를 생성합니다. `save`가 실패하고 레코드가 유효하지 않으면, 사용자가 잘못된 데이터를 수정할 수 있도록 폼을 다시 렌더링하고자 합니다. `else` 절에서는 다음을 수행합니다.

#### 제품 수정

레코드를 편집할 수 있어야 합니다. 이는 CRUD의 U(Update)에 해당합니다. 이미 `resources :creatives` 라우트로 개별 제품에 대한 라우트를 정의했기 때문에, 우리는 `/creatives/:id/edit` 라우트를 사용하여 `creatives#edit` 액션으로 연결할 수 있습니다. 이제 `CreativesController`에 `edit` 및 `update` 액션을 추가하고 동작을 정의해야 합니다.

### 컨트롤러에 `edit` 및 `update` 액션 구현

```ruby
#23-34
class CreativesController < ApplicationController
  def index
    @creatives = creative.all
  end

  def show
    @creative = creative.find(params[:id])
  end

  def new
    @creative = creative.new
  end

  def create
    @creative = creative.new(creative_params)
    if @creative.save
      redirect_to @creative
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @creative = creative.find(params[:id])
  end

  def update
    @creative = creative.find(params[:id])
    if @creative.update(creative_params)
      redirect_to @creative
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def creative_params
    params.expect(creative: [ :name ])
  end
end
```

다음으로 `CreativesController`의 `edit` 액션을 사용하여 제품을 수정하는 폼을 렌더링하고, `update` 액션을 통해 변경 사항을 저장할 수 있습니다.

### 개별 제품 표시

`CreativesController`를 열고 `show` 액션을 다음과 같이 추가하세요:

```ruby
class CreativesController < ApplicationController
  # 기존 액션 생략...

  def show
    @creative = creative.find(params[:id])
  end
end
```

여기서 `show` 액션은 단일 레코드를 데이터베이스에서 로드하므로 단수형 `@creative`를 정의합니다. 반면, `index`에서는 여러 제품을 로드하기 때문에 복수형 `@creatives`를 사용합니다. 데이터베이스를 쿼리하기 위해 `params`를 사용하여 요청 매개변수에 접근합니다. 이 경우, 라우트 `/creatives/:id`에서 `:id`를 사용하고 있습니다. `/creatives/1`을 방문하면 `params` 해시는 `{id: 1}`을 포함하게 되어, `show` 액션이 `creative.find(1)`을 호출하여 데이터베이스에서 ID가 `1`인 제품을 로드합니다.

다음으로 `show` 액션에 대한 뷰가 필요합니다. Rails 명명 규칙을 따르면, `CreativesController`는 `app/views` 내 `creatives`라는 하위 폴더에 뷰를 기대합니다. `show` 액션은 `app/views/creatives/show.html.erb` 파일을 기대합니다. 에디터에서 해당 파일을 생성하고 다음 내용을 추가하세요:

```erb
<h1><%= @creative.name %></h1>
<%= link_to "Back", creatives_path %>
```

인덱스 페이지에서 각 제품에 대한 상세 페이지로 이동할 수 있도록 링크를 추가하면 유용합니다.

`app/views/creatives/index.html.erb` 뷰를 업데이트하여 새 페이지로의 링크를 추가하고, `show` 액션의 경로에 앵커 태그를 사용하는 방법은 다음과 같습니다.

```erb
#6,8
<h1>creatives</h1>
<div id="creatives">
  <% @creatives.each do |creative| %>
    <div>
      <a href="/creatives/<%= creative.id %>">
        <%= creative.name %>
      </a>
    </div>
  <% end %>
</div>
```

이 페이지를 브라우저에서 새로 고치면 작동하지만, 더 나은 방법이 있습니다. Rails는 경로과 URL을 생성하기 위한 헬퍼 메서드를 제공합니다. `bin/rails routes`를 실행하면 Prefix 열을 확인할 수 있습니다. 이 Prefix는 Ruby 코드로 URL을 생성하는 데 사용할 수 있는 헬퍼와 일치합니다.

```bash
Prefix Verb
URI Pattern Controller#Action
creatives GET /creatives(.:format) creatives#index
creative GET /creatives/:id(.:format) creatives#show
```

이러한 라우트 프리픽스는 다음과 같은 헬퍼를 제공합니다:

* `creatives_path`는 `"/creatives"`를 생성합니다.
* `creatives_url`은 `"http://localhost:3000/creatives"`를 생성합니다.
* `creative_path(1)`은 `"/creatives/1"`을 생성합니다.
* `creative_url(1)`은 `"http://localhost:3000/creatives/1"`을 생성합니다.

`_path`는 현재 도메인에 대한 상대 경로를 반환하며, 브라우저가 이를 이해합니다. `_url`은 프로토콜, 호스트 및 포트를 포함한 전체 URL을 반환합니다. URL 헬퍼는 브라우저 외부에서 볼 이메일을 렌더링할 때 유용합니다. `link_to` 헬퍼와 결합하면 Ruby에서 깔끔하게 앵커 태그를 생성하고 URL 헬퍼를 사용할 수 있습니다. `link_to`는 링크의 표시 콘텐츠(`creative.name`)와 `href` 속성에 연결할 경로 또는 URL(`creative`)을 허용합니다. 이를 사용하여 다음과 같이 리팩토링할 수 있습니다:

```erb
#6
<h1>creatives</h1>
<div id="creatives">
  <% @creatives.each do |creative| %>
    <div>
      <%= link_to creative.name, creative %>
    </div>
  <% end %>
</div>
```

### 제품 생성

지금까지는 Rails 콘솔에서 제품을 생성해야 했지만, 이제 브라우저에서 이를 가능하게 해보겠습니다. 생성(Create)을 위해 두 개의 액션이 필요합니다:

1. 제품 정보를 수집하기 위한 새 제품 폼
2. 제품을 저장하고 오류를 확인하는 컨트롤러의 `create` 액션

먼저 컨트롤러 액션부터 시작하겠습니다.

```ruby
class CreativesController < ApplicationController
  def index
    @creatives = creative.all
  end

  def show
    @creative = creative.find(params[:id])
  end

  def new
    @creative = creative.new
  end

  def create
    @creative = creative.new(creative_params)
    if @creative.save
      redirect_to @creative
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @creative = creative.find(params[:id])
  end

  def update
    @creative = creative.find(params[:id])
    if @creative.update(creative_params)
      redirect_to @creative
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def creative_params
    params.expect(creative: [ :name ])
  end
end
```

다음으로 `edit` 액션을 `app/views/creatives/show.html.erb`에 추가하여 제품을 수정할 수 있는 링크를 추가합니다:

```erb
<h1><%= @creative.name %></h1>
<%= link_to "Back", creatives_path %>
<%= link_to "Edit", edit_creative_path(@creative) %>
```

#### 사전 액션

`edit`와 `update`는 `show`와 마찬가지로 기존 데이터베이스 레코드가 필요하기 때문에, 이를 `before_action`으로 중복 코드를 제거할 수 있습니다. `before
```ruby
def creative_params
  params.expect(creative: [:name])
end
end
```

이 기능을 작동하게 하려면, `app/views/creatives/show.html.erb`에 삭제 버튼을 추가해야 합니다:

```erb
#5
<h1><%= @creative.name %></h1>
<%= link_to "Back", creatives_path %>
<%= link_to "Edit", edit_creative_path(@creative) %>
<%= button_to "Delete", @creative, method: :delete, data: { turbo_confirm: "Are you sure?" } %>
```

`button_to`는 "Delete" 텍스트가 있는 단일 버튼을 포함하는 폼을 생성합니다. 이 버튼을 클릭하면 폼이 제출되어 `/creatives/:id`로 `DELETE` 요청을 보내고, 이는 컨트롤러의 `destroy` 액션을 트리거합니다. `turbo_confirm` 데이터 속성은 Turbo JavaScript 라이브러리에게 폼을 제출하기 전에 사용자가 확인할 수 있도록 요청합니다. 곧 이에 대해 더 자세히 살펴보겠습니다.

### 인증 추가
---
누구나 제품을 편집하거나 삭제할 수 있으므로 안전하지 않습니다. 제품을 관리하려면 사용자가 인증되어야 하도록 보안을 추가합시다. Rails는 인증을 위해 사용할 수 있는 인증 생성기를 제공합니다. 이 생성기는 User 및 Session 모델과 애플리케이션에 로그인하는 데 필요한 컨트롤러와 뷰를 생성합니다. 터미널로 돌아가 다음 명령을 실행하세요:

```bash
$ bin/rails generate authentication
```

그런 다음 데이터베이스를 마이그레이션하여 User 및 Session 테이블을 추가합니다.

```bash
$ bin/rails db:migrate
```

Rails 콘솔을 열어 User를 생성하세요.

```bash
$ bin/rails console
```

Rails 콘솔에서 `User.create!` 메서드를 사용하여 User를 생성합니다. 예제 대신 자신의 이메일과 비밀번호를 사용해도 됩니다.

```irb
store(dev)> User.create! email_address: "you@example.org", password: "s3cr3t", password_confirmation: "s3cr3t"
```

Rails 서버를 다시 시작하여 생성기에 의해 추가된 `bcrypt` 젬을 로드하도록 합니다. BCrypt는 인증을 위해 비밀번호를 안전하게 해싱하는 데 사용됩니다.

```bash
$ bin/rails server
```

페이지를 방문하면 Rails가 사용자 이름과 비밀번호를 입력하도록 요청합니다. User 레코드를 생성할 때 사용한 이메일과 비밀번호를 입력하세요.

### 로그 아웃 추가

애플리케이션에서 로그아웃하려면 `app/views/layouts/application.html.erb` 상단에 버튼을 추가할 수 있습니다. 이 레이아웃은 모든 페이지에 포함하고 싶은 HTML(예: 헤더나 푸터)을 넣는 곳입니다. `<body>` 내부에 작은 `<nav>` 섹션을 추가하여 홈 링크와 로그 아웃 버튼을 넣고 `<main>` 태그로 `yield`를 감쌉니다.

```erb
#5-8,10,12
<!DOCTYPE html>
<html>
<!-- ... -->
<body>
  <nav>
    <%= link_to "Home", root_path %>
    <%= button_to "Log out", session_path, method: :delete if authenticated? %>
  </nav>
  <main>
    <%= yield %>
  </main>
</body>
</html>
```

이것은 사용자가 인증된 경우에만 로그 아웃 버튼을 표시합니다. 클릭하면 세션 경로로 `DELETE` 요청을 보내 로그아웃합니다.

### 인증되지 않은 접근 허용

우리 상점의 제품 인덱스 및 상세 페이지는 모든 사용자에게 접근 가능해야 합니다. 기본적으로 Rails 인증 생성기는 모든 페이지를 인증된 사용자로 제한합니다.

인증되지 않은 접근을 허용하려면 컨트롤러에서 이를 허용할 수 있습니다.

```ruby
#2
class CreativesController < ApplicationController
  allow_unauthenticated_access only: %i[index show]
  # ...
end
```

로그아웃하고 제품 인덱스 및 상세 페이지를 방문하면 인증되지 않은 사용자가 접근할 수 있는 것을 확인할 수 있습니다.

### 인증된 사용자만 링크 표시

로그인한 사용자만 제품을 생성할 수 있으므로, `app/views/creatives/index.html.erb` 뷰를 수정하여 인증된 경우에만 새 제품 링크를 표시하도록 할 수 있습니다.

```erb
<%= link_to "New creative", new_creative_path if authenticated? %>
```

로그아웃 버튼을 클릭하면 인덱스 페이지에서 새 링크가 숨겨진 것을 볼 수 있습니다. `http://localhost:3000/session/new`에서 로그인하면 인덱스 페이지에서 새 링크가 표시됩니다. 옵션으로, 인증되지 않은 경우에만 로그인 링크를 네비게이션 바에 추가할 수도 있습니다.

```erb
<%= link_to "Login", new_session_path unless authenticated? %>
```

또한, `app/views/creatives/show.html.erb` 뷰의 편집 및 삭제 링크를 인증된 경우에만 표시하도록 업데이트할 수 있습니다.

```erb
#4,7
<h1><%= @creative.name %></h1>
<%= link_to "Back", creatives_path %>
<% if authenticated? %>
  <%= link_to "Edit", edit_creative_path(@creative) %>
  <%= button_to "Delete", @creative, method: :delete, data: { turbo_confirm: "Are you sure?" } %>
<% end %>
```

### 캐싱
---
#### 제품
페이지의 특정 부분을 캐싱하면 성능을 향상시킬 수 있습니다. Rails는 기본적으로 포함된 데이터베이스 기반 캐시 저장소인 Solid Cache를 통해 이 과정을 간단하게 만듭니다. `cache` 메서드를 사용하여 HTML을 캐시에 저장할 수 있습니다. `app/views/creatives/show.html.erb`에서 헤더를 캐싱해보겠습니다.

```erb
#1,3
<% cache @creative do %>
  <h1><%= @creative.name %></h1>
<% end %>
```

`@creative`를 `cache`에 전달하면 Rails는 제품에 대한 고유한 캐시 키를 생성합니다. Active Record 객체는 `"creatives/1"`과 같은 문자열을 반환하는 `cache_key` 메서드를 가지고 있습니다. 뷰의 `cache` 헬퍼는 템플릿 다이제스트와 결합하여 이 HTML에 대한 고유한 키를 생성합니다.

캐싱을 개발 환경에서 활성화하려면 터미널에서 다음 명령을 실행하세요.

```bash
$ bin/rails dev:cache
```

제품의 상세 액션(예: `/creatives/2`)을 방문하면 Rails 서버 로그에 새로운 캐싱 라인이 표시됩니다:

```bash
Read fragment views/creatives/show:a5a585f985894cd27c8b3d49bb81de3a/creatives/1-20240918154439539125 (1.6ms)
Write fragment views/creatives/show:a5a585f985894cd27c8b3d49bb81de3a/creatives/1-20240918154439539125 (4.0ms)
```

이 페이지를 처음 열 때 Rails는 캐시 키를 생성하고 캐시 저장소에 존재하는지 확인합니다. 이는 `Read fragment` 라인입니다. 첫 번째 페이지 뷰에서는 캐시가 존재하지 않으므로 HTML이 생성되어 캐시에 기록됩니다. 이는 로그의 `Write fragment` 라인으로 확인할 수 있습니다. 페이지를 새로 고치면 더 이상 `Write fragment`가 로그에 포함되지 않습니다.

```bash
Read fragment views/creatives/show:a5a585f985894cd27c8b3d49bb81de3a/creatives/1-20240918154439539125 (1.3ms)
```

이전 요청에 의해 캐시 항
```ruby
#2
class creative < ApplicationRecord
  has_one_attached :featured_image
  has_rich_text :description
  validates :name, presence: true
end
```

그런 다음 제출 버튼 전에 제품 양식에 파일 업로드 필드를 추가할 수 있습니다:

```erb#4-7
<%= form_with model: creative do |form| %>
  <%# ... %>
  <div>
    <%= form.label :featured_image, style: "display: block" %>
    <%= form.file_field :featured_image, accept: "image/*" %>
  </div>
  <div>
    <%= form.submit %>
  </div>
<% end %>
```

`app/controllers/creatives_controller.rb`에서 허용된 매개변수로 `:featured_image`를 추가하세요

```ruby#3
# Only allow a list of trusted parameters through.
def creative_params
  params.expect(creative: [ :name, :description, :featured_image ])
end
```

마지막으로, `app/views/creatives/show.html.erb`에서 제품의 대표 이미지를 표시하고자 합니다. 상단에 다음을 추가하세요.

```erb
<%= image_tag @creative.featured_image if @creative.featured_image.attached? %>
```

제품에 이미지를 업로드해 보세요. 저장 후 쇼 페이지에 이미지가 표시되는 것을 볼 수 있습니다. 자세한 내용은 [Active Storage Overview](https://guides.rubyonrails.org/active_storage_overview.html)를 참조하세요.

### 국제화 (I18n)
---------------------------

Rails는 애플리케이션을 다른 언어로 쉽게 번역할 수 있게 합니다. 뷰에서 `translate` 또는 `t` 헬퍼는 이름으로 번역을 조회하고 현재 로케일에 해당하는 텍스트를 반환합니다. `app/views/creatives/index.html.erb`에서 헤더 태그를 번역을 사용하도록 업데이트해 보겠습니다.

```erb
<h1><%= t "hello"
%></h1>
```

페이지를 새로 고치면, 헤더 텍스트가 이제 `Hello world`로 표시됩니다. 그게 어디서 온 것일까요? 기본 언어가 영어이기 때문에, Rails는 로케일 아래에서 일치하는 키를 찾기 위해 `rails new` 시 생성된 `config/locales/en.yml`을 참고합니다.

```yaml
en:
  hello: "Hello world"
```

스페인어에 대한 번역을 추가하기 위해 에디터에서 새 로케일 파일을 생성하고 `config/locales/es.yml`에 번역을 추가합시다.

```yaml
es:
  hello: "Hola mundo"
```

Rails에 어떤 로케일을 사용할지 알려줘야 합니다. 가장 간단한 방법은 URL에서 로케일 매개변수를 찾는 것입니다. 이를 `app/controllers/application_controller.rb`에서 다음과 같이 설정할 수 있습니다.

```ruby#4,6-9
class ApplicationController < ActionController::Base
  # ...
  around_action :switch_locale

  def switch_locale(&action)
    locale = params[:locale] || I18n.default_locale
    I18n.with_locale(locale, &action)
  end
end
```

이 설정은 모든 요청 시 실행되며, 매개변수에서 `locale`을 찾거나 기본 로케일로 대체합니다. 요청에 대한 로케일을 설정하고 요청이 끝난 후에는 이를 리셋합니다.

* [http://localhost:3000/creatives?locale=en](http://localhost:3000/creatives?locale=en)을 방문하면 영어 번역을 볼 수 있습니다.
* [http://localhost:3000/creatives?locale=es](http://localhost:3000/creatives?locale=es)을 방문하면 스페인어 번역을 볼 수 있습니다.
* 로케일 매개변수 없이 [http://localhost:3000/creatives](http://localhost:3000/creatives)을 방문하면 기본적으로 영어로 표시됩니다.

이제 인덱스 헤더를 `"Hello world"` 대신 실제 번역을 사용하도록 업데이트해 보겠습니다.

```erb
<h1><%= t ".title" %></h1>
```

**TIP:** `title` 앞의 `.`을 주목하세요. 이는 Rails에게 상대적인 로케일 조회를 사용하라고 지시합니다. 상대적 조회는 컨트롤러와 액션을 키에 자동으로 포함하므로 매번 이를 입력할 필요가 없습니다. 영어 로케일의 `.title`은 `en.creatives.index.title`을 조회하게 됩니다. `config/locales/en.yml`에서 컨트롤러, 뷰 및 번역 이름과 일치하도록 `creatives`와 `index` 아래에 `title` 키를 추가해야 합니다.

```yaml
en:
  hello: "Hello world"
  creatives:
    index:
      title: "creatives"
```

스페인어 로케일 파일에서도 같은 작업을 할 수 있습니다:

```yaml
es:
  hello: "Hola mundo"
  creatives:
    index:
      title: "Creativo"
```

이제 영어 로케일을 볼 때는 "creatives"가, 스페인어 로케일을 볼 때는 "Creativo"가 표시됩니다. [Rails Internationalization (I18n) API](https://guides.rubyonrails.org/i18n.html)에 대해 더 알아보세요.

### 재고 알림 추가
-----------------------------

전자상거래 상점의 일반적인 기능 중 하나는 제품이 재입고될 때 알림을 받기 위해 이메일을 구독하는 것입니다. 이제 Rails의 기본을 살펴보았으니, 이 기능을 상점에 추가해 보겠습니다.

#### 기본 재고 추적

먼저, 제품의
```ruby
resources :creatives do
  resources :subscribers, only: [ :create ]
end
```

### 제품에 사용자 구독 기능 추가

특정 제품에 사용자를 구독시키기 위해 중첩 라우트를 사용하여 구독자가 속한 제품을 알 수 있도록 합니다. `config/routes.rb`에서 `resources :creatives`를 다음과 같이 변경하세요:

```ruby
resources :creatives do
  resources :subscribers, only: [ :create ]
end
```

### 파일 업로드 필드 추가

제품 양식에 파일 업로드 필드를 추가하려면 제출 버튼 전에 다음과 같이 할 수 있습니다:

```erb
<%= form_with model: creative do |form| %>
  <%# ... %>
  <div>
    <%= form.label :featured_image, style: "display: block" %>
    <%= form.file_field :featured_image, accept: "image/*" %>
  </div>
  <div>
    <%= form.submit %>
  </div>
<% end %>
```

`app/controllers/creatives_controller.rb`에서 허용된 매개변수로 `:featured_image`를 추가하세요:

```ruby
# Only allow a list of trusted parameters through.
def creative_params
  params.require(:creative).permit(:name, :description, :featured_image)
end
```

### 제품 대표 이미지 표시

마지막으로, `app/views/creatives/show.html.erb`에서 제품의 대표 이미지를 표시하고자 합니다. 상단에 다음을 추가하세요:

```erb
<%= image_tag @creative.featured_image if @creative.featured_image.attached? %>
```

제품에 이미지를 업로드해 보세요. 저장 후 쇼 페이지에 이미지가 표시되는 것을 볼 수 있습니다. 자세한 내용은 [Active Storage Overview](https://guides.rubyonrails.org/active_storage_overview.html)를 참조하세요.

### 국제화 (I18n)
---------------------------

Rails는 애플리케이션을 다른 언어로 쉽게 번역할 수 있게 합니다. 뷰에서 `translate` 또는 `t` 헬퍼는 이름으로 번역을 조회하고 현재 로케일에 해당하는 텍스트를 반환합니다. `app/views/creatives/index.html.erb`에서 헤더 태그를 번역을 사용하도록 업데이트해 보겠습니다.

```erb
<h1><%= t "hello" %></h1>
```

페이지를 새로 고치면, 헤더 텍스트가 이제 `Hello world`로 표시됩니다. 그게 어디서 온 것일까요? 기본 언어가 영어이기 때문에, Rails는 로케일 아래에서 일치하는 키를 찾기 위해 `rails new` 시 생성된 `config/locales/en.yml`을 참고합니다.

```yaml
en:
  hello: "Hello world"
```

스페인어에 대한 번역을 추가하기 위해 에디터에서 새 로케일 파일을 생성하고 `config/locales/es.yml`에 번역을 추가합시다.

```yaml
es:
  hello: "Hola mundo"
```

Rails에 어떤 로케일을 사용할지 알려줘야 합니다. 가장 간단한 방법은 URL에서 로케일 매개변수를 찾는 것입니다. 이를 `app/controllers/application_controller.rb`에서 다음과 같이 설정할 수 있습니다.

```ruby
class ApplicationController < ActionController::Base
  # ...
  around_action :switch_locale

  def switch_locale(&action)
    locale = params[:locale] || I18n.default_locale
    I18n.with_locale(locale, &action)
  end
end
```

이 설정은 모든 요청 시 실행되며, 매개변수에서 `locale`을 찾거나 기본 로케일로 대체합니다. 요청에 대한 로케일을 설정하고 요청이 끝난 후에는 이를 리셋합니다.

* [http://localhost:3000/creatives?locale=en](http://localhost:3000/creatives?locale=en)을 방문하면 영어 번역을 볼 수 있습니다.
* [http://localhost:3000/creatives?locale=es](http://localhost:3000/creatives?locale=es)을 방문하면 스페인어 번역을 볼 수 있습니다.
* 로케일 매개변수 없이 [http://localhost:3000/creatives](http://localhost:3000/creatives)을 방문하면 기본적으로 영어로 표시됩니다.

이제 인덱스 헤더를 `"Hello world"` 대신 실제 번역을 사용하도록 업데이트해 보겠습니다.

```erb
<h1><%= t ".title" %></h1>
```

**TIP:** `title` 앞의 `.`을 주목하세요. 이는 Rails에게 상대적인 로케일 조회를 사용하라고 지시합니다. 상대적 조회는 컨트롤러와 액션을 키에 자동으로 포함하므로 매번 이를 입력할 필요가 없습니다. 영어 로케일의 `.title`은 `en.creatives.index.title`을 조회하게 됩니다. `config/locales/en.yml`에서 컨트롤러, 뷰 및 번역 이름과 일치하도록 `creatives`와 `index` 아래에 `title` 키를 추가해야 합니다.

```yaml
en:
  hello: "Hello world"
  creatives:
    index:
      title: "creatives"
```

스페인어 로케일 파일에서도 같은 작업을 할 수 있습니다:

```yaml
es:
  hello: "Hola mundo"
  creatives:
    index:
      title: "Creativo"
```

이제 영어 로케일을 볼 때는 "creatives"가, 스페인어 로케일을 볼 때는 "Creativo"가 표시됩니다. [Rails Internationalization (I18n) API](https://guides.rubyonrails.org/i18n.html)에 대해 더 알아보세요.

### 재고 알림 추가
-----------------------------

전자상거래 상점의 일반적인 기능 중 하나는 제품이 재입고될 때 알림을 받기 위해 이메일을 구독하는 것입니다. 이제 Rails의 기본을 살펴보았으니, 이 기능을 상점에 추가해 보겠습니다.

#### 기본 재고 추적

먼저, 제품의

```ruby

class creative < ApplicationRecord
  has_one_attached :featured_image
  has_rich_text :description
  has_many :subscribers, dependent: :destroy
  validates :name, presence: true
  validates :inventory_count, numericality: { greater_than_or_equal_to: 0 }
  after_update_commit :notify_subscribers, if: :back_in_stock?

  def back_in_stock?
    inventory_count_previously_was.zero? && inventory_count > 0
  end

  def notify_subscribers
    subscribers.each do |subscriber|
      CreativeMailer.with(creative: self, subscriber: subscriber).in_stock.deliver_later
    end
  end
end
```

`after_update_commit`은 데이터베이스에 변경 사항이 저장된 후에 실행되는 Active Record 콜백입니다. `if: :back_in_stock?`는 `back_in_stock?` 메서드가 `true`를 반환할 때만 콜백이 실행되도록 합니다. Active Record는 속성의 변경 사항을 추적하므로 `back_in_stock?`은 `inventory_count_previously_was`를 사용하여 `inventory_count`의 이전 값을 확인할 수 있습니다. 그런 다음 이를 현재 재고 수와 비교하여 제품이 다시 재고가 되었는지 판단합니다. `notify_subscribers`는 Active Record 연관을 사용하여 이 특정 제품에 대한 모든 구독자를 조회하고 각 구독자에게 `in_stock` 이메일을 보내도록 큐에 추가합니다.

### Concerns 추출
-----------------------------

creative 모델에는 이제 알림을 처리하는 상당한 양의 코드가 포함되어 있습니다. 코드를 더 잘 조직하기 위해 이를 `ActiveSupport::Concern`으로 추출할 수 있습니다. Concern은 루비 모듈로, 사용을 더 쉽게 하기 위한 구문 설탕을 포함하고 있습니다. 먼저 Notifications 모듈을 생성해 보겠습니다. `app/models/creative/notifications.rb` 파일을 생성하고 다음 내용을 추가하세요:

```ruby

module creative::Notifications
  extend ActiveSupport::Concern

  included do
    has_many :subscribers, dependent: :destroy
    after_update_commit :notify_subscribers, if: :back_in_stock?
  end

  def back_in_stock?
    inventory_count_previously_was == 0 && inventory_count > 0
  end

  def notify_subscribers
    subscribers.each do |subscriber|
      CreativeMailer.with(creative: self, subscriber: subscriber).in_stock.deliver_later
    end
  end
end
```

모듈을 클래스에 포함하면 `included` 블록 내부의 모든 코드는 마치 해당 클래스의 일부인 것처럼 실행됩니다. 동시에 모듈에 정의된 메서드는 해당 클래스의 객체(인스턴스)에서 호출 가능한 일반적인 메서드가 됩니다. 이제 알림을 트리거하는 코드가 Notifications 모듈로 추출되었으므로,

creative 모델을 Notifications 모듈을 포함하도록 단순화할 수 있습니다.

```ruby
class creative < ApplicationRecord
  include Notifications
  has_one_attached :featured_image
  has_rich_text :description
  validates :name, presence: true
  validates :inventory_count, numericality: { greater_than_or_equal_to: 0 }
end
```

Concerns는 Rails 애플리케이션의 기능을 조직화하는 훌륭한 방법입니다. Creative에 더 많은 기능을 추가하면 클래스가 복잡해질 수 있습니다. 대신, Concerns를 사용하여 각 기능을 `creative::Notifications`와 같이 자체 포함된 모듈로 추출할 수 있습니다. 이는 구독자를 처리하고 알림을 보내는 모든 기능을 포함합니다. Concerns로 코드를 추출하면 기능의 재사용성을 높일 수 있습니다. 예를 들어, 구독자 알림이 필요한 새로운 모델을 도입할 경우 이 모듈을 여러 모델에서 동일한 기능을 제공하도록 사용할 수 있습니다.

### 구독 취소 링크
-----------------------------

구독자는 언제든지 구독을 취소하고 싶을 수 있으므로, 이를 구축해 보겠습니다. 먼저, 이메일에 포함할 구독 취소 URL을 위한 라우트가 필요합니다.

```ruby
resource :unsubscribe, only: [ :show ]
```

Active Record에는 `generates_token_for`라는 기능이 있어, 다양한 목적으로 데이터베이스 레코드를 찾기 위한 고유한 토큰을 생성할 수 있습니다. 이를 사용하여 이메일의 구독 취소 URL에 사용할 고유한 토큰을 생성할 수 있습니다.

```ruby
class Subscriber < ApplicationRecord
  belongs_to :creative
  generates_token_for :unsubscribe
end
```

컨트롤러는 먼저 URL의 토큰을 사용하여 Subscriber 레코드를 찾습니다. 구독자가 발견되면 레코드를 삭제하고 홈페이지로 리다이렉트합니다. `app/controllers/unsubscribes_controller.rb`를 생성하고 다음 코드를 추가하세요:

```ruby
class UnsubscribesController < ApplicationController
  allow_unauthenticated_access
  before_action :set_subscriber

  def show
    @subscriber&.destroy
    redirect_to root_path, notice: "Unsubscribed successfully."
  end

  private

  def set_subscriber
    @subscriber = Subscriber.find_by_token_for(:unsubscribe, params[:token])
  end
end
```

마지막으로, 이메일 템플릿에 구독 취소 링크를 추가합시다. `app/views/creative_mailer/in_stock.html.erb`에서 `link_to`를 추가하세요:

```erb
<h1>Good news!</h1>
<p><%= link_to @creative.name, creative_url(@creative) %> is back in stock.</p>
<p><%= link_to "Unsubscribe", unsubscribe_path(token: @subscriber.unsubscribe_token) %></p>
```

이제 구독자들은 이메일에서 직접 구독을 취소할 수 있는 링크를 사용할 수 있습니다.
```erb
<p><%= link_to @creative.name, creative_url(@creative) %> is back in stock.</p> <%= link_to "Unsubscribe", unsubscribe_url(token: params[:subscriber].generate_token_for(:unsubscribe)) %>
```

`app/views/creative_mailer/in_stock.text.erb`에 URL을 평문으로 추가하세요:

```erb
#6
Good news! <%= @creative.name %> is back in stock.
<%= creative_url(@creative) %>
Unsubscribe: <%= unsubscribe_url(token: params[:subscriber].generate_token_for(:unsubscribe)) %>
```

구독 취소 링크를 클릭하면 구독자 레코드가 데이터베이스에서 삭제됩니다. 컨트롤러는 오류를 발생시키지 않고 유효하지 않거나 만료된 토큰을 안전하게 처리합니다. Rails 콘솔을 사용하여 다른 이메일을 보내고 로그에서 구독 취소 링크를 테스트할 수 있습니다.

CSS 및 JavaScript 추가
-----------------------

CSS와 JavaScript는 웹 애플리케이션을 구축하는 데 핵심적인 요소이므로 Rails와 함께 사용하는 방법을 배워봅시다.

### Propshaft

Rails의 자산 파이프라인은 Propshaft라고 불립니다. CSS, JavaScript, 이미지 및 기타 자산을 가져와 브라우저에 제공합니다. 프로덕션 환경에서는 Propshaft가 자산의 각 버전을 추적하여 페이지를 더 빠르게 캐시할 수 있도록 합니다. 이 작동 방식에 대해 더 알고 싶다면 [Asset Pipeline 가이드](https://guides.rubyonrails.org/asset_pipeline.html)를 확인하세요.

`app/assets/stylesheets/application.css`를 수정하여 글꼴을 산세리프로 변경해 보겠습니다.

```css
body {
  font-family: Arial, Helvetica, sans-serif;
  padding: 1rem;
}
nav {
  justify-content: flex-end;
  display: flex;
  font-size: 0.875em;
  gap: 0.5rem;
  max-width: 1024px;
  margin: 0 auto;
  padding: 1rem;
}
nav a {
  display: inline-block;
}
main {
  max-width: 1024px;
  margin: 0 auto;
}
.notice {
  color: green;
}
section.creative {
  display: flex;
  gap: 1rem;
  flex-direction: row;
}
section.creative img {
  border-radius: 8px;
  flex-basis: 50%;
  max-width: 50%;
}
```

그런 다음 `app/views/creatives/show.html.erb`를 업데이트하여 새로운 스타일을 적용합니다.

```erb
#1,3,6,18-19
<p><%= link_to "Back", creatives_path %></p>
<section class="creative">
  <%= image_tag @creative.featured_image if @creative.featured_image.attached? %>
  <section class="creative-info">
    <% cache @creative do %>
      <h1><%= @creative.name %></h1>
      <%= @creative.description %>
    <% end %>
    <%= render "inventory", creative: @creative %>
    <% if authenticated? %>
      <%= link_to "Edit", edit_creative_path(@creative) %>
      <%= button_to "Delete",
        @creative, method: :delete, data: { turbo_confirm: "Are you sure?" } %>
    <% end %>
  </section>
</section>
```

페이지를 새로 고치면 CSS가 적용된 것을 볼 수 있습니다.

### Import Maps

Rails는 기본적으로 JavaScript용으로 import maps를 사용합니다. 이를 통해 빌드 단계 없이 최신 JavaScript 모듈을 작성할 수 있습니다. JavaScript 핀은 `config/importmap.rb`에서 확인할 수 있습니다. 이 파일은 JavaScript 패키지 이름을 소스 파일과 매핑하여 브라우저에서 importmap 태그를 생성하는 데 사용됩니다.

```ruby
# Pin npm packages by running ./bin/importmap pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
```

TIP: 각 핀은 JavaScript 패키지 이름(예: `"@hotwired/turbo-rails"`)을 특정 파일이나 URL(예: `"turbo.min.js"`)과 매핑합니다. `pin_all_from`은 디렉터리 내의 모든 파일(예: `app/javascript/controllers`)을 네임스페이스(예: `"controllers"`)와 매핑합니다. Import maps는 설정을 깔끔하고 최소화된 상태로 유지하면서도 최신 JavaScript 기능을 지원합니다. 우리의 import map에 이미 있는 JavaScript 파일들은 무엇일까요? 기본적으로 Rails에서 사용하는 프론트엔드 프레임워크인 Hotwire입니다.

### Hotwire

Hotwire는 서버 측에서 생성된 HTML을 최대한 활용하도록 설계된 JavaScript 프레임워크입니다. 3개의 핵심 구성 요소로 구성됩니다:

1. [**Turbo**](https://turbo.hotwired.dev/)는 네비게이션, 폼 제출, 페이지 구성 요소 및 업데이트를 커스텀 JavaScript를 작성하지 않고 처리합니다.
2. [**Stimulus**](https://stimulus.hotwired.dev/)는 페이지에 기능을 추가하기 위해 커스텀 JavaScript가 필요할 때 프레임워크를 제공합니다.
3. [**Native**](https://native.hotwired.dev/)는 웹 앱을 내장하고 네이티브 모바일 기능을 점진적으로 향상시켜 하이브리드 모바일 앱을 만들 수 있게 합니다.

아직 JavaScript를 작성하지 않았지만 프론트엔드에서 Hotwire를 사용해왔습니다. 예를 들어, 제품을 추가하고 편집하기 위해 만든 폼은 Turbo에 의해 구동되었습니다. [Asset Pipeline](https://guides.rubyonrails.org/asset_pipeline.html)과 [Working with JavaScript in Rails](https://guides.rubyonrails.org/working_with_javascript_in_rails.html) 가이드에서 자세히 알아보세요.

테스팅
-------

Rails는 강력한 테스트 스위트를 제공합니다. 제품이 재입고될 때 올바른 수의 이메일이 전송되는지 확인하는 테스트를 작성해 보겠습니다.

### Fixtures

Rails에서 모델을 생성하면 자동으로 `test/fixtures` 디렉터리에 해당하는 피처처 파일이 생성됩니다. 피처처는 테스트를 실행하기 전에 테스트 데이터베이스를 채우는 미리 정의된 데이터 세트입니다. 이는 테스트에서 쉽게 접근할 수 있는 이름으로 레코드를 정의할 수 있게 하여, 테스트에서 레코드 ID와 연관성을 관리할 필요가 없게 합니다. 이 파일은 기본적으로 비어 있으며, 테스트를 위한 피처처로 채워야 합니다.

`test/fixtures/creatives.yml` 파일을 다음과 같이 업데이트해 보겠습니다:

```yaml
tshirt:
  name: T-Shirt
  inventory_count: 15
```

그리고 `test/fixtures/subscribers.yml`에 다음 두 개의 피처처를 추가합니다:

```yaml
david:
  creative: tshirt
  email: david@example.org

chris:
  creative: tshirt
  email: chris@example.org
```

여기에서 `creative` 피처처를 이름으로 참조할 수 있음을 알 수 있습니다. Rails는 데이터베이스에서 이를 자동으로 연결하므로 테스트에서 레코드 ID와 연관성을 관리할 필요가 없습니다. 이 피처처는 테스트 스위트를 실행할 때 자동으로 데이터베이스에 삽입됩니다.

### 이메일 테스트

`test/models/creative_test.rb`에 다음 테스트를 추가해 보겠습니다:

```ruby
require "test_helper"

class CreativeTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  test "sends email notifications when back in stock" do
    creative = creatives(:tshirt)
    # Set creative out of stock
    creative.update(inventory_count: 0)

    assert_emails 2 do
      creative.update(inventory_count: 99)
    end
  end
end
```

이 테스트가 수행하는 작업을 살펴보겠습니다. 먼저, 테스트 중에 전송된 이메일을 모니터링할 수 있도록 Action Mailer 테스트 헬퍼를 포함합니다. `tshirt` 피처처는 `creatives()` 피처처 헬퍼를 사용하여 해당 레코드의 Active Record 객체를 반환합니다. 각 피처처는 이름으로 참조할 수 있는 헬퍼를 테스트 스위트에 생성하므로, 실행할 때마다 다를 수 있는 데이터베이스 ID를 관리할 필요가 없습니다. 그런 다음, 재고가 없는 상태로 설정하기 위해 제품의 재고를 0으로 업데이트합니다. 다음으로, `assert_emails`를 사용하여 블록 내에서 생성된 이메일이 2개인지 확인합니다. 이메일을 트리거하기 위해 블록 내에서 제품의 재고 수를 업데이트합니다. 이는 제품 모델의 `notify_subscribers` 콜백을 트리거하여 이메일을 전송하게 합니다. 작업이 완료되면 `assert_emails`가 이메일 수를 세어 예상된 수와 일치하는지 확인합니다.

테스트 스위트는 `bin/rails test`를 사용하여 실행하거나 파일 이름을 전달하여 개별 테스트 파일을 실행할 수 있습니다.

```bash
$ bin/rails test test/models/creative_test.rb
Running 1 tests in a single process (parallelization threshold is 50)
Run options: --seed 3556

# Running:
.

Finished in 0.343842s, 2.9083 runs/s, 5.8166 assertions/s.

1 runs, 2 assertions, 0 failures, 0 errors, 0 skips
```

테스트가 성공적으로 통과했습니다! Rails는 `CreativeMailer`에 대한 예제 테스트를 `test/mailers/creative_mailer_test.rb`에 생성했습니다. 이를 업데이트하여 테스트가 통과하도록 만들어 보겠습니다.

```ruby
require "test_helper"

class CreativeMailerTest < ActionMailer::TestCase
  test "in_stock" do
    mail = CreativeMailer.with(creative: creatives(:tshirt), subscriber: subscribers(:david)).in_stock

    assert_equal "In stock", mail.subject
    assert_equal ["david@example.org"], mail.to
    assert_equal ["from@example.com"], mail.from
    assert_match "Good news!", mail.body.encoded
  end
end
```

전체 테스트 스위트를 실행하여 모든 테스트가 통과하는지 확인해 보겠습니다.

```bash
$ bin/rails test
Running 2 tests in a single process (parallelization threshold is 50)
Run options: --seed 16302

# Running:
..

Finished in 0.665856s, 3.0037 runs/s, 10.5128 assertions/s.

2 runs, 7 assertions, 0 failures, 0 errors, 0 skips
```

테스트가 모두 통과했습니다! 이를 시작점으로 삼아 테스트 스위트를 계속 확장해 나갈 수 있습니다.
애플리케이션 기능의 전체 커버리지. [Rails 애플리케이션 테스트](https://guides.rubyonrails.org/testing.html)에 대해 더 알아보기  
RuboCop으로 일관된 코드 포맷 ----------------------------------------  
코드를 작성할 때 때때로 일관되지 않은 포맷을 사용할 수 있습니다. Rails에는 RuboCop이라는 린터가 포함되어 있어 코드의 포맷을 일관되게 유지하는 데 도움을 줍니다. 다음 명령어를 실행하여 코드의 일관성을 확인할 수 있습니다:

```bash
$ bin/rubocop
```

이 명령어는 모든 위반 사항을 출력하고 어떤 문제들이 있는지 알려줍니다.

```bash
Inspecting 53 files .....................................................
53 files inspected, no offenses detected
```

RuboCop은 `--autocorrect` 플래그(또는 짧은 버전인 `-a`)를 사용하여 위반 사항을 자동으로 수정할 수 있습니다.

```bash
$ bin/rubocop -a
```

보안 --------  
Rails는 Brakeman gem을 포함하여 애플리케이션의 보안 문제를 확인합니다. 이는 세션 하이재킹, 세션 고정, 리디렉션과 같은 공격으로 이어질 수 있는 취약점을 검사합니다. `bin/brakeman`을 실행하면 애플리케이션을 분석하고 보고서를 출력합니다.

```bash
$ bin/brakeman

Loading scanner...
...
== Overview ==
Controllers: 6
Models: 6
Templates: 15
Errors: 0
Security Warnings: 0

== Warning Types ==
No warnings found
```

[Securing Rails Applications](https://guides.rubyonrails.org/security.html)에 대해 더 알아보기

GitHub Actions를 사용한 지속적 통합 ------------------------------------------  
Rails 애플리케이션은 rubocop, brakeman, 그리고 테스트 스위트를 실행하는 사전 작성된 GitHub Actions 구성을 포함하는 `.github` 폴더를 생성합니다. 우리가 GitHub Actions가 활성화된 GitHub 리포지토리에 코드를 푸시하면, 이러한 단계가 자동으로 실행되고 각 단계의 성공 또는 실패를 보고합니다. 이를 통해 코드 변경 사항의 결함 및 문제를 모니터링하고 작업의 일관된 품질을 보장할 수 있습니다.

프로덕션에 배포 -----------------------  
이제 재미있는 단계입니다: 애플리케이션을 배포해 봅시다. Rails에는 [Kamal](https://kamal-deploy.org)이라는 배포 도구가 포함되어 있어 애플리케이션을 서버에 직접 배포할 수 있습니다. Kamal은 Docker 컨테이너를 사용하여 애플리케이션을 실행하고 무중단으로 배포합니다. 기본적으로 Rails에는 프로덕션 준비가 완료된 Dockerfile이 포함되어 있습니다.

Kamal은 이 Dockerfile을 사용하여 Docker 이미지를 빌드하고, 모든 종속성과 설정을 포함한 애플리케이션의 컨테이너화된 버전을 생성합니다. 이 Dockerfile은 [Thruster](https://github.com/basecamp/thruster)를 사용하여 프로덕션에서 자산을 효율적으로 압축하고 제공합니다. Kamal을 사용하여 배포하려면 다음이 필요합니다:

- **1GB 이상의 RAM을 갖춘 Ubuntu LTS 서버**  
  서버는 장기 지원(LTS) 버전의 Ubuntu 운영 체제를 실행해야 하며, 정기적인 보안 및 버그 수정이 제공됩니다. Hetzner, DigitalOcean 및 기타 호스팅 서비스에서 시작할 수 있는 서버를 제공합니다.
  
- **[Docker Hub](https://hub.docker.com) 계정 및 액세스 토큰**  
  Docker Hub는 애플리케이션의 이미지를 저장하여 서버에서 다운로드하고 실행할 수 있도록 합니다. Docker Hub에서 애플리케이션 이미지를 위한 [리포지토리 생성](https://hub.docker.com/repository/create)을 합니다. 리포지토리 이름으로 "store"를 사용하세요. `config/deploy.yml`을 열고 `192.168.0.1`을 서버의 IP 주소로, `your-user`를 Docker Hub 사용자 이름으로 교체합니다.

```yaml
# 애플리케이션 이름. 컨테이너를 고유하게 구성하는 데 사용됩니다.
service: store

# 컨테이너 이미지의 이름.
image: your-user/store

# 배포할 서버.
servers:
  web:
    - 192.168.0.1

# 이미지 호스트에 대한 자격 증명.
registry:
  # Docker Hub를 사용하지 않는 경우 레지스트리 서버를 지정합니다.
  # server: registry.digitalocean.com / ghcr.io / ...
  username:
```

`proxy:` 섹션 아래에 도메인을 추가하여 애플리케이션에 SSL을 활성화할 수 있습니다. DNS 레코드가 서버를 가리키도록 설정하고 Kamal은 LetsEncrypt를 사용하여 도메인에 대한 SSL 인증서를 발급합니다.

```yaml
proxy:
  ssl: true
  host: app.example.com
```

Docker 웹사이트에서 Read & Write 권한을 가진 [액세스 토큰 생성](https://app.docker.com/settings/personal-access-tokens/create)을 통해 Kamal이 애플리케이션의 Docker 이미지를 푸시할 수 있도록 합니다. 그런 다음 터미널에서 액세스 토큰을 내보내 Kamal이 이를 찾을 수 있도록 합니다.

```bash
export KAMAL_REGISTRY_PASSWORD=your-access-token
```

다음 명령어를 실행하여 서버를 설정하고 애플리케이션을 처음으로 배포합니다.

```bash
$ bin/kamal setup
```

축하합니다! 새 Rails 애플리케이션이 라이브 상태로 프로덕션에 배포되었습니다! 새 Rails 애플리케이션을 확인하려면 브라우저를 열고 서버의 IP 주소를 입력하세요. 상점이 실행되는 것을 볼 수 있을 것입니다. 이후 애플리케이션에 변경 사항을 적용하고 프로덕션에 푸시하려면 다음 명령어를 실행할 수 있습니다.

```bash
$ bin/kamal deploy
```

### 프로덕션에 사용자 추가  
프로덕션에서 제품을 생성 및 편집하려면 프로덕션 데이터베이스에 사용자 레코드가 필요합니다. Kamal을 사용하여 프로덕션 Rails 콘솔을 열 수 있습니다.

```bash
$ bin/kamal console
```

```ruby
store(prod)> User.create!(email_address: "you@example.org", password: "s3cr3t", password_confirmation: "s3cr3t")
```

이제 이 이메일과 비밀번호로 프로덕션에 로그인하여 제품을 관리할 수 있습니다.

### Solid Queue를 사용하는 백그라운드 작업  
백그라운드 작업은 사용자 경험을 방해하지 않고 별도의 프로세스에서 비동기적으로 작업을 실행할 수 있게 해줍니다. 예를 들어, 10,000명의 수신자에게 재고 이메일을 보내는 작업을 상상해 보십시오. 시간이 걸릴 수 있으므로 이 작업을 백그라운드 작업으로 오프로드하여 Rails 애플리케이션의 반응성을 유지할 수 있습니다. 개발 환경에서는 Rails가 ActiveJob과 함께 백그라운드 작업을 처리하기 위해 `:async` 큐 어댑터를 사용합니다. Async는 메모리에 보류 중인 작업을 저장하지만 재시작 시 보류 중인 작업을 잃어버립니다. 이는 개발에 적합하지만 프로덕션에는 적합하지 않습니다. 백그라운드 작업을 보다 견고하게 만들기 위해 Rails는 프로덕션 환경에서 `solid_queue`를 사용합니다. Solid Queue는 작업을 데이터베이스에 저장하고 별도의 프로세스에서 실행합니다. Solid Queue는 `config/deploy.yml`의 `SOLID_QUEUE_IN_PUMA: true` 환경 변수를 사용하여 프로덕션 Kamal 배포에 활성화됩니다. 이는 웹 서버인 Puma에 Solid Queue 프로세스를 자동으로 시작 및 중지하도록 지시합니다. Action Mailer의 `deliver_later`로 이메일을 보낼 때, 이러한 이메일은 HTTP 요청을 지연시키지 않고 백그라운드에서 전송됩니다. 프로덕션에서 Solid Queue를 사용하면 이메일이 백그라운드에서 전송되고, 전송에 실패할 경우 자동으로 재시도되며, 재시작 중에도 데이터베이스에 작업이 안전하게 보관됩니다.

```html
<picture class="flowdiagram">
  <source srcset="images/getting_started/background_jobs_dark.jpg" media="(prefers-color-scheme:dark)">
  <img src="images/getting_started/background_jobs_light.jpg">
</picture>
```

다음 단계는? ------------  
첫 번째 Rails 애플리케이션을 구축하고 배포한 것을 축하드립니다! 계속해서 기능을 추가하고 업데이트를 배포하면서 학습을 이어가는 것을 권장합니다. 다음은 몇 가지 아이디어입니다:

* CSS로 디자인 개선
* 제품 리뷰 추가
* 애플리케이션을 다른 언어로 번역 완료
* 결제용 체크아웃 플로우 추가
* 사용자가 제품을 저장할 수 있는 위시리스트 추가
* 제품 이미지용 캐러셀 추가

또한 다른 Ruby on Rails 가이드를 읽어 추가로 학습하는 것을 권장합니다:

* [Active Record 기초](https://guides.rubyonrails.org/active_record_basics.html)
* [Rails에서의 레이아웃 및 렌더링](https://guides.rubyonrails.org/layouts_and_rendering.html)
* [Rails 애플리케이션 테스트](https://guides.rubyonrails.org/testing.html)
* [Rails 애플리케이션 디버깅](https://guides.rubyonrails.org/debugging_rails_applications.html)
* [Rails 애플리케이션 보안](https://guides.rubyonrails.org/security.html)

즐거운 개발 되세요!
