#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

export BUILD_ONLY="${INPUT_BUILD_ONLY:-"false"}"

env_file="_action.env"
if [[ -f $env_file ]]; then

  echo -e "$YELLOW+------------------------------------------+$NC"
  echo -e "$YELLOW| $env_file exists, entering debug mode. |$NC"
  echo -e "$YELLOW+------------------------------------------+$NC"
  source $env_file
fi

resolve_app_name() {
  export APP_NAME="${INPUT_APP_NAME:-"$(echo $GITHUB_REPOSITORY | cut -d/ -f2)"}"

  echo "App name: $APP_NAME"
}

resolve_environment() {
  if [[ -z "$INPUT_ENVIRONMENT" ]]; then
    echo "Environment not set, using branch name."
    export BRANCH_NAME="$(echo $GITHUB_REF | cut -d/ -f3)"

    if [[ "$BRANCH_NAME" == "master" ]] || [[ "$BRANCH_NAME" == "main" ]]; then
      export ENVIRONMENT="production"
    else
      echo "Not in master or main, using staging as default."
      export ENVIRONMENT="staging"
    fi
  else
    echo "Environment set, using it."
    export ENVIRONMENT="$INPUT_ENVIRONMENT"
  fi
  
  export ENVIROMENT_SLUG="$(echo $ENVIRONMENT | cut -c1-4)"
  echo "Environment: $ENVIRONMENT"
  echo "Environment slug: $ENVIROMENT_SLUG"
}

resolve_image_tag() {
  # INPUT_IMAGE_TAG is always set by the user
  echo "🔍 Starting image tag resolution..."

  if [[ "$INPUT_IMAGE_TAG" =~ ^[0-9a-f]{40}$ ]]; then
    echo -e "$YELLOW""Image tag looks like a commit sha, prepending it with additional info to ensure uniqueness.$NC"

    branch_slug=$(echo $GITHUB_REF | cut -d/ -f3- | sed 's/[^a-zA-Z0-9\/-]//g' | sed 's/\//_/g' | cut -c1-42)
    sha_slug=$(echo $INPUT_IMAGE_TAG | cut -c1-8)

    echo "Environment slug: $ENVIROMENT_SLUG"
    echo "Branch slug: $branch_slug"
    echo "SHA slug: $sha_slug"

    export IMAGE_TAG="$ENVIROMENT_SLUG.$branch_slug.$sha_slug"
  else
    echo "Image tag is not a commit sha, using it as is."
    export IMAGE_TAG="$INPUT_IMAGE_TAG"
  fi

  export IMAGE_OWNER="${INPUT_IMAGE_OWNER}"
  export IMAGE_REPO="${INPUT_IMAGE_REPO:-$APP_NAME}"
  export DESTINATION="$IMAGE_OWNER/$IMAGE_REPO:$IMAGE_TAG"
  
  echo -e "${YELLOW}Resolved image: $DESTINATION$NC"
  
  if [[ "$IMAGE_OWNER" == *"ecr"* ]]; then
    echo "🔍 Checking if image already exists in ECR container registry..."
    ECR_REPO="$IMAGE_REPO"
    ECR_TAG="$IMAGE_TAG"    
    
    AWS_REGION=$(echo $IMAGE_OWNER | cut -d '.' -f 4)    

    if aws ecr describe-images --repository-name "$ECR_REPO" --image-ids imageTag="$ECR_TAG" --region "$AWS_REGION" &> /dev/null; then
      echo -e "$GREEN""✅ Image $DESTINATION already exists in container registry.$NC"
      echo -e "$GREEN""✅ Skipping build and push to save time and resources.$NC"
      export SKIP_BUILD_AND_PUSH="true"
      export IMAGE_EXISTS="true"
    else
      echo -e "$YELLOW""🔍 Image $DESTINATION does not exist in container registry.$NC"
      echo -e "$YELLOW""🔨 Will proceed with build and push.$NC"
      export SKIP_BUILD_AND_PUSH="false"
      export IMAGE_EXISTS="false"
    fi
  else    
    echo "🔍 Checking if image already exists in container registry..."
    if docker pull "$DESTINATION" &> /dev/null; then
      echo -e "$GREEN""✅ Image $DESTINATION already exists in container registry.$NC"
      echo -e "$GREEN""✅ Skipping build and push to save time and resources.$NC"
      export SKIP_BUILD_AND_PUSH="true"
      export IMAGE_EXISTS="true"
    else
      echo -e "$YELLOW""🔍 Image $DESTINATION does not exist in container registry.$NC"
      echo -e "$YELLOW""🔨 Will proceed with build and push.$NC"
      export SKIP_BUILD_AND_PUSH="false"
      export IMAGE_EXISTS="false"
    fi
  fi

  echo "Final image tag: $IMAGE_TAG"
  echo "Skip build and push flag: $SKIP_BUILD_AND_PUSH"
  echo "Image exists flag: $IMAGE_EXISTS"
}

setup_git() {
  git config --global user.email "infra@anota.ai" || exit 1
  git config --global user.name "Infrastructure Team" || exit 1
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

  export DEPLOYMENT_REPO_CLONE_URL="https://oauth2:$DEPLOYMENT_REPO_TOKEN@github.com/$DEPLOYMENT_REPO"

  echo "Cloning deployment repo."
  echo "URL: $DEPLOYMENT_REPO_CLONE_URL"

  git clone "$DEPLOYMENT_REPO_CLONE_URL" "$DEPLOYMENT_REPO_PATH" || exit 1
}

setup_docker_credentials() {
  export AWS_ECR_SERVER="${INPUT_IMAGE_OWNER}"
  # get region inside ecr server url
  export AWS_REGION=$(echo $INPUT_IMAGE_OWNER | cut -d '.' -f 4)
  export AWS_ACCESS_KEY_ID=${INPUT_DOCKER_BUILD_REGISTRY_USERNAME}
  export AWS_SECRET_ACCESS_KEY=${INPUT_DOCKER_BUILD_REGISTRY_PASSWORD}

  # check authentication
  aws sts get-caller-identity || exit 1

  aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $AWS_ECR_SERVER
}

build_image() {
  echo "🏗️ Starting build process..."
  
  # Skip both build and push if image already exists
  if [[ "$SKIP_BUILD_AND_PUSH" == "true" ]]; then
    echo -e "$GREEN""⏩ Skipping build for existing image: $DESTINATION$NC"
    echo -e "$GREEN""⏩ Using existing image from container registry$NC"
    echo -e "$GREEN""⏩ This saves CI/CD time and resources$NC"
    
    # Set this variable so the deployment process knows to use the existing image
    export IMAGE_EXISTS="true"
    return 0
  fi

  echo -e "$YELLOW""🏗️ Building image: $DESTINATION$NC"
  
  export CONTEXT="${INPUT_DOCKER_BUILD_CONTEXT_PATH:-"."}"
  export DOCKERFILE="-f ${INPUT_DOCKER_BUILD_DOCKERFILE_PATH:-"./Dockerfile"}"
  export ENVIRONMENT_BUILD_ARG="--build-arg ENVIRONMENT=${ENVIRONMENT}"
  export ARGS="$DOCKERFILE $ENVIRONMENT_BUILD_ARG $CONTEXT -t $DESTINATION"

  echo "Docker build context: $CONTEXT"
  echo "Dockerfile path: $DOCKERFILE"
  echo "Environment build arg: $ENVIRONMENT_BUILD_ARG"
  echo "Full docker build command: docker build $ARGS"

  echo -e "$YELLOW""Starting docker build...$NC"
  docker build $ARGS || { 
    echo -e "$RED""❌ Docker build failed$NC"
    exit 1
  }
  
  echo -e "$GREEN""✅ Docker build successful$NC"
  echo -e "$YELLOW""Pushing image to container registry: $DESTINATION$NC"
  
  # Try to push the image, but handle the case where the repository is immutable
  if ! docker push "$DESTINATION" 2>&1 | tee /tmp/docker_push_output.log; then
    if grep -q "repository is immutable" /tmp/docker_push_output.log; then
      echo -e "$YELLOW""⚠️ Repository is immutable and image tag already exists.$NC"
      echo -e "$YELLOW""⚠️ Using the existing image from the container registry.$NC"
      export IMAGE_EXISTS="true"
      return 0
    else
      echo -e "$RED""❌ Docker push failed for an unknown reason$NC"
      exit 1
    fi
  fi
  
  echo -e "$GREEN""✅ Successfully pushed image to container registry: $DESTINATION$NC"
}

set_tag_on_yamls() {
  export ALL_YAMLS_FOUND="true"
  export IMGTAG_KEY="${INPUT_DEPLOYMENT_REPO_YAML_IMGTAG_KEY:-"image.tag"}"
  readarray -t DEPLOYMENT_REPO_YAML_PATHS <<<"$INPUT_DEPLOYMENT_REPO_YAML_PATHS"
  unset DEPLOYMENT_REPO_YAML_PATHS[-1]

  for YAML_PATH in "${DEPLOYMENT_REPO_YAML_PATHS[@]}"; do
    YAML_PATH="$( echo $DEPLOYMENT_REPO_PATH/$YAML_PATH | sed 's/ENVIRONMENT/'$ENVIRONMENT'/g' | sed 's/APP_NAME/'$APP_NAME'/g' )"
    echo "Editing YAML: $YAML_PATH"
    if [[ ! -f "$YAML_PATH" ]]; then
      echo "::error ::Could not find one of the application deployment files (is it deployed on the cluster?): $YAML_PATH"
      ALL_YAMLS_FOUND="false"
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
  git fetch || exit 1
  if [[ $(git rev-parse HEAD) != $(git rev-parse @{u}) ]]; then
    echo "Remote has changes, pulling them."
    git pull || exit 1
  else 
    echo "Remote is up to date."
  fi
  git commit -m "chore(${APP_NAME}/${ENVIRONMENT}): updating image tag :)" || exit 1
  git push || exit 1
}

done_msg() {
  echo -e "${GREEN}+----------------------------------------+$NC"
  echo -e "${GREEN}|                  DONE!                 |$NC"
  echo -e "${GREEN}+----------------------------------------+$NC"
}

echo -e "${GREEN}+----------------------------------------+$NC"
echo -e "${GREEN}|      Running Deploy                    |$NC"
echo -e "${GREEN}+----------------------------------------+$NC"

echo "If you have any issues, please contact infra@anota.ai"

echo "::group::Resolving variables"
resolve_app_name
resolve_environment
resolve_image_tag
echo "::endgroup::"

echo "::group::Setting up docker credentials"
setup_docker_credentials

echo "::group::Setting up Git Credentials"
setup_git
echo "::endgroup"

echo "::group::Building Docker Image"
build_image
echo "::endgroup::"

if [[ "$BUILD_ONLY" == "true" ]]; then
  echo "Only building and pushing image, exiting..."
  done_msg
  exit 0
fi

echo "::group::Update image tag on Deployment Repository"
clone_deployment_repo
set_tag_on_yamls
check_if_is_already_updated
push

if [[ "$ALL_YAMLS_FOUND" == "false" ]]; then
  echo "::error ::Failing because one of the application deployment files was not found. Please check the logs."
  exit 1
fi

echo "::endgroup::"
done_msg
