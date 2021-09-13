#!/usr/bin/env bash

export GITHUB_REPOSITORY="githubanotaai/testapp"
export APP_NAME="testapp"
export GITHUB_REF="refs/heads/master"
export INPUT_DEPLOYMENT_REPO="githubanotaai/applications"
export INPUT_IMAGE_OWNER="igrowdigital"
# export INPUT_IMAGE_REPO=""
export INPUT_IMAGE_TAG="latest123123"
export INPUT_DOCKER_BUILD_DOCKERFILE_PATH="test/Dockerfile"
export INPUT_DOCKER_BUILD_CONTEXT_PATH="test/"
export INPUT_DEPLOYMENT_REPO_YAML_PATHS="applications/testapp/ENV/values.yaml"
export INPUT_DEPLOYMENT_REPO_YAML_IMGTAG_KEY="image.tag"

bash entrypoint.sh