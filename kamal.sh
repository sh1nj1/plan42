# `bundle binstubs dotenv` creates ./bin/dotenv
./bin/dotenv --overwrite -f ".env.${RAILS_ENV:-production}" ./bin/kamal $@
