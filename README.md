# docker-curl-pull

### usage
```sh
# Public image (anonymous)
export IMAGE="library/nginx" TAG="latest"
./docker-pull-curl.sh

# Private image (authenticated)
export IMAGE="myuser/myapp" TAG="v1.2.3"
export DOCKER_USER="myuser" DOCKER_PASS="my_token_or_password"
./docker-pull-curl.sh
```