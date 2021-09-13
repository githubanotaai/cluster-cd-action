#!/bin/bash

#   app_name: backstage

#   deployment_repo: githubanotaai/infrastructure
#   deployment_repo_token: ${{ secrets.DEPLOYMENT_REPO_TOKEN }}
#   deployment_repo_yaml_paths: production/backstage/values.yaml
#   deployment_repo_yaml_imgtag_key: backend.image.tag

#   image_owner: igrowdigital
#   image_repo: backstage-backend
#   image_tag: ${{ github.sha }}

#   docker_build_registry_password: ${{ secrets.DOCKERHUB_PASSWORD }}
#   docker_build_registry_username: ${{ secrets.DOCKERHUB_USERNAME }}
#   docker_build_dockerfile_path: packages/app/Dockerfile
#   docker_build_context_path: .


resolve_app_name() {
  export APP_NAME="${INPUT_APP_NAME:-"$(echo $GITHUB_REPOSITORY | cut -d/ -f2)"}"

  echo "App name: $APP_NAME"
}

resolve_environment() {
  export ENVIRONMENT="$(echo $GITHUB_REF | cut -d/ -f3)"

  if [[ "${ENVIRONMENT}" == "master" ]] || [[ "${ENVIRONMENT}" == "main" ]]; then
    export ENVIRONMENT="production"
  fi

  if [[ "${ENVIRONMENT}" == "develop" ]]; then
    export ENVIRONMENT="staging"
  fi

  echo "Environment: $ENVIRONMENT"
}

setup_git() {
  git config --local user.email "actions@github.com"
  git config --local user.name "GitHub Actions"
}

clone_deployment_repo() {
  export DEPLOYMENT_REPO="${INPUT_DEPLOYMENT_REPO}"
  export DEPLOYMENT_REPO_TOKEN="${INPUT_DEPLOYMENT_REPO_TOKEN}"
  export DEPLOYMENT_REPO_PATH="$PWD/deployment-repo"
  export DEPLOYMENT_REPO_CLONE_URL="https://$DEPLOYMENT_REPO_TOKEN@github.com/$DEPLOYMENT_REPO"

  echo "Cloning deployment repo."
  echo "URL: $DEPLOYMENT_REPO_CLONE_URL"

  git clone "$DEPLOYMENT_REPO_CLONE_URL" "$DEPLOYMENT_REPO_PATH" 
}

setup_docker_credentials() {
  export DOCKER_BUILD_REGISTRY_USER=${INPUT_DOCKER_BUILD_REGISTRY_USER}
  export DOCKER_BUILD_REGISTRY_PASSWORD=${INPUT_DOCKER_BUILD_REGISTRY_PASSWORD}
  export DOCKERHUB_AUTH="$(echo -n $DOCKER_BUILD_REGISTRY_USER:$DOCKER_BUILD_REGISTRY_PASSWORD | base64)"

  mkdir -p $HOME/.docker/

cat <<EOF >$HOME/.docker/config.json
{
        "auths": {
                "https://index.docker.io/v1/": {
                        "auth": "${DOCKERHUB_AUTH}"
                }
        }
}
EOF

  cat $HOME/.docker/config.json
}

build_image() {
  export IMAGE_OWNER="${INPUT_IMAGE_OWNER}"
  export IMAGE_REPO="${INPUT_IMAGE_REPO:-$APP_NAME}"
  export IMAGE_TAG="${INPUT_IMAGE_TAG}"

  echo "Image: $IMAGE_OWNER/$IMAGE_REPO:$IMAGE_TAG"

  export CONTEXT="${INPUT_DOCKER_BUILD_CONTEXT_PATH:-"."}"
  export DOCKERFILE="--file ${INPUT_DOCKER_BUILD_DOCKERFILE_PATH:-"./Dockerfile"}"
  export DESTINATION="--tag $IMAGE_OWNER/$IMAGE_REPO:$IMAGE_TAG"
  export ARGS="--driver-opt image=moby/buildkit:master --push $DESTINATION $DOCKERFILE $CONTEXT"

  echo "Building image"
  echo "args: $ARGS"

  buildx build $ARGS || exit 1
}

set_tag_on_yamls() {
  export IMGTAG_KEY="${INPUT_DEPLOYMENT_REPO_YAML_IMGTAG_KEY:-"image.tag"}"
  IFS=';' read -r -a DEPLOYMENT_REPO_YAML_PATHS <<< "$INPUT_DEPLOYMENT_REPO_YAML_PATHS"

  for YAML_PATH in "${DEPLOYMENT_REPO_YAML_PATHS[@]}"; do
    YAML_PATH="$( echo $DEPLOYMENT_REPO_PATH/$YAML_PATH | sed 's/ENV/'$ENVIRONMENT'/g' )"
    echo "Editing YAML: $YAML_PATH"
    yq w -i ${YAML_PATH} ${IMGTAG_KEY} ${IMAGE_TAG} || exit 1
    cd "$DEPLOYMENT_REPO_PATH"
    git add "$YAML_PATH"
    cd "$OLDPWD"
  done
}

push() {
  cd "$DEPLOYMENT_REPO_PATH"
  git commit -m "chore(${APP_NAME}): bumping ${ENVIRONMENT} image tag"
  git push
}

setup_docker_credentials
setup_git

resolve_app_name
resolve_environment

build_image
clone_deployment_repo
set_tag_on_yamls
push