
# FAQ

### 개발시 CSS 수정후 즉시 반영 안됨

아래와 같이 해야 반영 되는 문제가 있었음

* `rails assets:precompile`
* `bin/importmap json`
* restart server

해결:

* `rm -rf public/assets`

### open prod console

`kamal app exec -i ./bin/rails console`

### show docker volume path

`docker volume inspect plan42_storage`

