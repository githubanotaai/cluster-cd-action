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

GREEN='\033[0;32m'
NC='\033[0m'

if [[ -f .env ]]; then
  echo ".env exists, entering debug mode."
  source .env
fi

resolve_app_name() {
  export APP_NAME="${INPUT_APP_NAME:-"$(echo $GITHUB_REPOSITORY | cut -d/ -f2)"}"

  echo "App name: $APP_NAME"
}

resolve_environment() {
  export ENVIRONMENT="$(echo $GITHUB_REF | cut -d/ -f3)"

  if [[ "${ENVIRONMENT}" == "master" ]] || [[ "${ENVIRONMENT}" == "main" ]]; then
    export ENVIRONMENT="prod"
  else
    export ENVIRONMENT="staging"
  fi

  echo "Environment: $ENVIRONMENT"
}

setup_git() {
  git config --global user.email "actions@github.com" || exit 1
  git config --global user.name "GitHub Actions" || exit 1
  git config --global --add safe.directory /github/workspace || exit 1
}

clone_deployment_repo() {
  export DEPLOYMENT_REPO="${INPUT_DEPLOYMENT_REPO}"
  export DEPLOYMENT_REPO_TOKEN="${INPUT_DEPLOYMENT_REPO_TOKEN}"

  if [[ "$GITHUB_ACTIONS" == "true" ]]; then
    export DEPLOYMENT_REPO_PATH="/deployment-repo"
  else
    export DEPLOYMENT_REPO_PATH="$PWD/deployment-repo"
  fi

  export DEPLOYMENT_REPO_CLONE_URL="https://$DEPLOYMENT_REPO_TOKEN@github.com/$DEPLOYMENT_REPO"

  echo "Cloning deployment repo."
  echo "URL: $DEPLOYMENT_REPO_CLONE_URL"

  git clone "$DEPLOYMENT_REPO_CLONE_URL" "$DEPLOYMENT_REPO_PATH" || exit 1
}

setup_docker_credentials() {
  export DOCKER_BUILD_REGISTRY_USERNAME=${INPUT_DOCKER_BUILD_REGISTRY_USERNAME}
  export DOCKER_BUILD_REGISTRY_PASSWORD=${INPUT_DOCKER_BUILD_REGISTRY_PASSWORD}

  docker login -u "$DOCKER_BUILD_REGISTRY_USERNAME" -p "$DOCKER_BUILD_REGISTRY_PASSWORD" || exit 1
}

build_image() {
  export IMAGE_OWNER="${INPUT_IMAGE_OWNER}"
  export IMAGE_REPO="${INPUT_IMAGE_REPO:-$APP_NAME}"
  export IMAGE_TAG="$(echo commit-$INPUT_IMAGE_TAG | cut -c1-16)"

  echo "Image: $IMAGE_OWNER/$IMAGE_REPO:$IMAGE_TAG"

  export CONTEXT="${INPUT_DOCKER_BUILD_CONTEXT_PATH:-"."}"
  export DOCKERFILE="-f ${INPUT_DOCKER_BUILD_DOCKERFILE_PATH:-"./Dockerfile"}"
  export DESTINATION="$IMAGE_OWNER/$IMAGE_REPO:$IMAGE_TAG"
  export ARGS="$DOCKERFILE $CONTEXT -t $DESTINATION"

  echo "Building image"
  echo "docker build args: $ARGS"

  docker build $ARGS || exit 1

  docker push "$DESTINATION" || exit 1
}

set_tag_on_yamls() {
  export IMGTAG_KEY="${INPUT_DEPLOYMENT_REPO_YAML_IMGTAG_KEY:-"image.tag"}"
  readarray -t DEPLOYMENT_REPO_YAML_PATHS <<<"$INPUT_DEPLOYMENT_REPO_YAML_PATHS"
  unset DEPLOYMENT_REPO_YAML_PATHS[-1]

  for YAML_PATH in "${DEPLOYMENT_REPO_YAML_PATHS[@]}"; do
    YAML_PATH="$( echo $DEPLOYMENT_REPO_PATH/$YAML_PATH | sed 's/ENV/'$ENVIRONMENT'/g' | sed 's/APP_NAME/'$APP_NAME'/g' )"
    echo "Editing YAML: $YAML_PATH"
    if [[ ! -f "$YAML_PATH" ]]; then
      echo "::error ::Could not find one of the application deployment files (is it deployed on the cluster?): $YAML_PATH"
    else
      yq w --style double -i ${YAML_PATH} ${IMGTAG_KEY} ${IMAGE_TAG} || exit 1
      cd "$DEPLOYMENT_REPO_PATH"
      git add "$YAML_PATH" || exit 1
      cd "$OLDPWD"
    fi
  done
}

check_if_is_already_updated() {
  cd "$DEPLOYMENT_REPO_PATH"
  if [[ $(git status --porcelain) ]]; then
    echo "Detected changes, pushing...."
  else
    echo -e "${GREEN}Already updated, exiting."
    exit 0
  fi
}

push() {
  cd "$DEPLOYMENT_REPO_PATH"
  git commit -m "chore(${APP_NAME}): bumping ${ENVIRONMENT} image tag" || exit 1
  git push || exit 1
}

echo -e "${GREEN}+----------------------------------------+"
echo -e "${GREEN}|      Starting to Deploy to Cluster     |"
echo -e "${GREEN}+----------------------------------------+"

echo "If you have any issue, please contact rsouza@anota.ai"

echo "::group::Resolving variables"
resolve_app_name
resolve_environment
echo "::endgroup::"

echo "::group::Setting up docker credentials"
setup_docker_credentials
echo "::endgroup::"

echo "::group::Setting up Git Credentials"
setup_git
echo "::endgroup"

echo "::group::Building Docker Image"
build_image
echo "::endgroup::"

echo "::group::Update image tag on Deployment Repository"
clone_deployment_repo
set_tag_on_yamls
check_if_is_already_updated
push
echo "::endgroup::"

echo -e "${GREEN}+----------------------------------------+"
echo -e "${GREEN}|                  DONE!                 |"
echo -e "${GREEN}+----------------------------------------+"
