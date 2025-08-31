# Deploy to AWS EC2

## Create docker hub repository

- create account
- create personal access token and set it in OS env `KAMAL_REGISTRY_PASSWORD`
- create repository named as `ror_getting_started_store`

## Create EC2 instance

using t2.micro, AWS Linux

### Configuration for SSH

```bash
sudo apt update
sudo apt upgrade -y
sudo apt install -y docker.io curl git
sudo usermod -a -G docker ec2-user
```

for AWS Linux
```bash
sudo yum update -y
sudo yum install -y docker
sudo service docker start
sudo usermod -a -G docker ec2-user
```

## Configure config/deploy.yml

configure config/deploy.yml

```yaml
service: ror_getting_started_store
image: <docker hub username>/ror_getting_started_store
servers:
  web:
    - <EC2 server IP address>
proxy:
  host: ror-getting-started-store.example.com
ssh:
  user: ec2-user
  keys_only: true
  keys: [ "~/.ssh/id.pem" ] # set ec2 private key
```

If you're deploying to an ARM-based instance like a Graviton `t4g.small`, set the builder architecture in `config/deploy.yml`:

```yaml
builder:
  arch: arm64
```

run deploy

```bash
bin/kamal deploy
```

## References

- [Kamal SSH Configuration](https://kamal-deploy.org/docs/configuration/ssh/)

