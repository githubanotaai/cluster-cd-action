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
  echo -e "$BLUE""┌─────────────────────────────────────────────┐$NC"
  echo -e "$BLUE""│       🔍 IMAGE TAG RESOLUTION               │$NC"
  echo -e "$BLUE""└─────────────────────────────────────────────┘$NC"

  if [[ "$GITHUB_REF" == refs/tags/* ]]; then
    TAG_NAME="${GITHUB_REF#refs/tags/}"
    echo -e "$YELLOW""📝 Detected git tag push. Using tag as image tag: $TAG_NAME$NC"
    export IMAGE_TAG="$TAG_NAME"
    
  elif [[ "$INPUT_IMAGE_TAG" =~ ^[0-9a-f]{40}$ ]]; then
    echo -e "$YELLOW""📝 Image tag looks like a commit SHA, creating a more descriptive tag...$NC"

    branch_slug=$(echo $GITHUB_REF | cut -d/ -f3- | sed 's/[^a-zA-Z0-9\/-]//g' | sed 's/\//_/g' | cut -c1-42)
    sha_slug=$(echo $INPUT_IMAGE_TAG | cut -c1-8)

    echo -e "$CYAN""   ├─ Environment slug: $ENVIROMENT_SLUG$NC"
    echo -e "$CYAN""   ├─ Branch slug: $branch_slug$NC"
    echo -e "$CYAN""   └─ SHA slug: $sha_slug$NC"

    export IMAGE_TAG="$ENVIROMENT_SLUG.$branch_slug.$sha_slug"
  else
    echo -e "$YELLOW""📝 Using provided image tag as is.$NC"
    export IMAGE_TAG="$INPUT_IMAGE_TAG"
  fi

  export IMAGE_OWNER="${INPUT_IMAGE_OWNER}"
  export IMAGE_REPO="${INPUT_IMAGE_REPO:-$APP_NAME}"
  export DESTINATION="$IMAGE_OWNER/$IMAGE_REPO:$IMAGE_TAG"
  
  echo -e "$GREEN""✅ Resolved image: $DESTINATION$NC"
  
  echo -e "$BLUE""┌─────────────────────────────────────────────┐$NC"
  echo -e "$BLUE""│       🔍 IMAGE EXISTENCE CHECK              │$NC"
  echo -e "$BLUE""└─────────────────────────────────────────────┘$NC"
  
  if [[ "$IMAGE_OWNER" == *"ecr"* ]]; then
    echo -e "$YELLOW""📡 Checking if image exists in AWS ECR registry...$NC"
    
    # Set up AWS credentials before checking ECR
    export AWS_ECR_SERVER="${INPUT_IMAGE_OWNER}"
    export AWS_REGION=$(echo $INPUT_IMAGE_OWNER | cut -d '.' -f 4)
    export AWS_ACCESS_KEY_ID=${INPUT_DOCKER_BUILD_REGISTRY_USERNAME}
    export AWS_SECRET_ACCESS_KEY=${INPUT_DOCKER_BUILD_REGISTRY_PASSWORD}
    
    # Verify credentials are working
    echo -e "$CYAN""   ├─ Verifying AWS credentials...$NC"
    if ! aws sts get-caller-identity > /dev/null 2>&1; then
      echo -e "$RED""   ├─ ❌ AWS credentials verification failed$NC"
      echo -e "$RED""   └─ ⚠️ Unable to check if image exists, will proceed with build$NC"
      export SKIP_BUILD_AND_PUSH="false"
      export IMAGE_EXISTS="false"
      return
    fi
    
    echo -e "$GREEN""   ├─ ✅ AWS credentials verified$NC"
    
    ECR_TAG="$IMAGE_TAG"
    AWS_ACCOUNT_ID=$(echo $IMAGE_OWNER | cut -d '.' -f 1)
    
    echo -e "$CYAN""   ├─ Registry ID: $AWS_ACCOUNT_ID$NC"
    echo -e "$CYAN""   ├─ Repository: $IMAGE_REPO$NC"
    echo -e "$CYAN""   ├─ Image tag: $ECR_TAG$NC"
    echo -e "$CYAN""   └─ Region: $AWS_REGION$NC"
    
    ECR_OUTPUT_FILE=$(mktemp)
    
    echo -e "$YELLOW""📡 Querying ECR API...$NC"
    if aws ecr describe-images --repository-name "$IMAGE_REPO" --image-ids imageTag="$ECR_TAG" --region "$AWS_REGION" --registry-id "$AWS_ACCOUNT_ID" > "$ECR_OUTPUT_FILE" 2>&1; then
      echo -e "$GREEN""✅ Image $DESTINATION exists in ECR registry$NC"
      echo -e "$GREEN""✅ Skipping build and push to save time and resources$NC"
      
      # Extract and display image details
      IMAGE_DIGEST=$(cat "$ECR_OUTPUT_FILE" | jq -r '.imageDetails[0].imageDigest' 2>/dev/null || echo "N/A")
      IMAGE_SIZE=$(cat "$ECR_OUTPUT_FILE" | jq -r '.imageDetails[0].imageSizeInBytes' 2>/dev/null || echo "N/A")
      if [[ "$IMAGE_SIZE" != "N/A" ]]; then
        IMAGE_SIZE_MB=$(echo "scale=2; $IMAGE_SIZE / 1024 / 1024" | bc)
        IMAGE_SIZE="$IMAGE_SIZE_MB MB"
      fi
      PUSHED_AT=$(cat "$ECR_OUTPUT_FILE" | jq -r '.imageDetails[0].imagePushedAt' 2>/dev/null || echo "N/A")
      
      echo -e "$CYAN""   ├─ Image digest: $IMAGE_DIGEST$NC"
      echo -e "$CYAN""   ├─ Image size: $IMAGE_SIZE$NC"
      echo -e "$CYAN""   └─ Pushed at: $PUSHED_AT$NC"
      
      export SKIP_BUILD_AND_PUSH="true"
      export IMAGE_EXISTS="true"
    else
      echo -e "$YELLOW""🔍 Image $DESTINATION does not exist in ECR registry$NC"
      echo -e "$YELLOW""🔨 Will proceed with build and push$NC"
      
      # Display error for debugging
      ERROR_MSG=$(cat "$ECR_OUTPUT_FILE")
      if [[ -n "$ERROR_MSG" ]]; then
        echo -e "$RED""   └─ Error: $ERROR_MSG$NC"
      fi
      
      export SKIP_BUILD_AND_PUSH="false"
      export IMAGE_EXISTS="false"
    fi
    
    rm -f "$ECR_OUTPUT_FILE"
  else
    echo -e "$YELLOW""📡 Checking if image exists in Docker registry...$NC"
    DOCKER_OUTPUT_FILE=$(mktemp)
    
    if docker pull "$DESTINATION" > "$DOCKER_OUTPUT_FILE" 2>&1; then
      echo -e "$GREEN""✅ Image $DESTINATION exists in Docker registry$NC"
      echo -e "$GREEN""✅ Skipping build and push to save time and resources$NC"
      
      # Get image details
      IMAGE_ID=$(docker inspect --format='{{.Id}}' "$DESTINATION" 2>/dev/null || echo "N/A")
      IMAGE_CREATED=$(docker inspect --format='{{.Created}}' "$DESTINATION" 2>/dev/null || echo "N/A")
      
      echo -e "$CYAN""   ├─ Image ID: $IMAGE_ID$NC"
      echo -e "$CYAN""   └─ Created: $IMAGE_CREATED$NC"
      
      export SKIP_BUILD_AND_PUSH="true"
      export IMAGE_EXISTS="true"
    else
      echo -e "$YELLOW""🔍 Image $DESTINATION does not exist in Docker registry$NC"
      echo -e "$YELLOW""🔨 Will proceed with build and push$NC"
      
      # Display error for debugging
      ERROR_MSG=$(cat "$DOCKER_OUTPUT_FILE")
      if [[ -n "$ERROR_MSG" ]]; then
        echo -e "$RED""   └─ Error: $ERROR_MSG$NC"
      fi
      
      export SKIP_BUILD_AND_PUSH="false"
      export IMAGE_EXISTS="false"
    fi
    
    rm -f "$DOCKER_OUTPUT_FILE"
  fi

  echo -e "$BLUE""┌─────────────────────────────────────────────┐$NC"
  echo -e "$BLUE""│       📋 IMAGE TAG SUMMARY                  │$NC"
  echo -e "$BLUE""└─────────────────────────────────────────────┘$NC"
  echo -e "$CYAN""   ├─ Final image tag: $IMAGE_TAG$NC"
  echo -e "$CYAN""   ├─ Skip build and push: $SKIP_BUILD_AND_PUSH$NC"
  echo -e "$CYAN""   └─ Image exists: $IMAGE_EXISTS$NC"
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
  echo -e "$BLUE""┌─────────────────────────────────────────────┐$NC"
  echo -e "$BLUE""│       🏗️ BUILD PROCESS                      │$NC"
  echo -e "$BLUE""└─────────────────────────────────────────────┘$NC"
  
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
  export READONLY_GH_TOKEN_ARG="--build-arg READONLY_GH_TOKEN=${INPUT_READONLY_GH_TOKEN:-""}"
  export ARGS="$DOCKERFILE $ENVIRONMENT_BUILD_ARG $READONLY_GH_TOKEN_ARG $CONTEXT -t $DESTINATION"

  echo -e "$CYAN""   ├─ Docker build context: $CONTEXT$NC"
  echo -e "$CYAN""   ├─ Dockerfile path: $DOCKERFILE$NC"
  echo -e "$CYAN""   ├─ Environment build arg: $ENVIRONMENT_BUILD_ARG$NC"
  echo -e "$CYAN""   └─ Full docker build command: docker build $ARGS$NC"

  echo -e "$YELLOW""🚀 Starting docker build...$NC"
  if docker build $ARGS; then
    echo -e "$GREEN""✅ Docker build successful$NC"
  else
    echo -e "$RED""❌ Docker build failed$NC"
    exit 1
  fi

  echo -e "$YELLOW""📤 Pushing image to container registry: $DESTINATION$NC"
  if docker push $DESTINATION; then
    echo -e "$GREEN""✅ Successfully pushed image to container registry: $DESTINATION$NC"
  else
    PUSH_EXIT_CODE=$?
    if [[ $PUSH_EXIT_CODE -eq 1 ]] && docker push $DESTINATION 2>&1 | grep -q "already exists"; then
      echo -e "$YELLOW""⚠️ Image already exists in registry (repository is immutable)$NC"
      echo -e "$GREEN""✅ Using existing image: $DESTINATION$NC"
    else
      echo -e "$RED""❌ Docker push failed for an unknown reason$NC"
      exit 1
    fi
  fi
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

# Retry mechanism with exponential backoff
push_with_retry() {
  local max_retries=3
  local base_delay=5
  local attempt=1
  
  cd "$DEPLOYMENT_REPO_PATH"
  
  while [[ $attempt -le $max_retries ]]; do
    echo -e "${YELLOW}🔄 Attempt $attempt/$max_retries: Syncing with remote repository...${NC}"
    
    # Fetch latest changes
    if ! git fetch; then
      echo -e "${RED}❌ Failed to fetch from remote${NC}"
      if [[ $attempt -eq $max_retries ]]; then
        send_slack_notification "Failed to fetch from deployment-catalog after $max_retries attempts"
        exit 1
      fi
      ((attempt++))
      continue
    fi
    
    # Check if remote has changes and pull with rebase
    if [[ $(git rev-parse HEAD) != $(git rev-parse @{u}) ]]; then
      echo -e "${YELLOW}📥 Remote has changes, pulling with rebase...${NC}"
      if ! git pull --rebase; then
        echo -e "${RED}❌ Failed to pull with rebase${NC}"
        if [[ $attempt -eq $max_retries ]]; then
          send_slack_notification "Failed to pull changes from deployment-catalog after $max_retries attempts"
          exit 1
        fi
        ((attempt++))
        continue
      fi
    else 
      echo -e "${GREEN}✅ Remote is up to date${NC}"
    fi
    
    # Commit changes
    echo -e "${YELLOW}💾 Committing changes...${NC}"
    if ! git commit -m "chore(${APP_NAME}/${ENVIRONMENT}): updating image tag :)"; then
      echo -e "${RED}❌ Failed to commit changes${NC}"
      if [[ $attempt -eq $max_retries ]]; then
        send_slack_notification "Failed to commit changes to deployment-catalog after $max_retries attempts"
        exit 1
      fi
      ((attempt++))
      continue
    fi
    
    # Push changes
    echo -e "${YELLOW}📤 Pushing changes...${NC}"
    if git push; then
      echo -e "${GREEN}✅ Successfully pushed changes to deployment-catalog${NC}"
      return 0
    else
      local push_exit_code=$?
      echo -e "${RED}❌ Failed to push changes (exit code: $push_exit_code)${NC}"
      
      if [[ $attempt -eq $max_retries ]]; then
        send_slack_notification "Failed to push changes to deployment-catalog after $max_retries attempts. Manual intervention required."
        exit 1
      fi
      
      # Calculate exponential backoff delay
      local delay=$((base_delay * (2 ** (attempt - 1))))
      echo -e "${YELLOW}⏳ Waiting ${delay}s before retry...${NC}"
      sleep $delay
      ((attempt++))
    fi
  done
}

# Slack notification function
send_slack_notification() {
  local message="$1"
  local slack_webhook="${INPUT_SLACK_WEBHOOK_URL:-}"
  
  if [[ -z "$slack_webhook" ]]; then
    echo -e "${YELLOW}⚠️ Slack webhook not configured, skipping notification${NC}"
    return 0
  fi
  
  local payload=$(cat <<EOF
{
  "channel": "#anotaai-deploys-prod",
  "username": "DeploymentBot",
  "icon_emoji": ":warning:",
  "text": "🚨 *Deployment Catalog Commit Failure*",
  "attachments": [
    {
      "color": "danger",
      "fields": [
        {
          "title": "Repository",
          "value": "$GITHUB_REPOSITORY",
          "short": true
        },
        {
          "title": "Environment", 
          "value": "$ENVIRONMENT",
          "short": true
        },
        {
          "title": "App Name",
          "value": "$APP_NAME", 
          "short": true
        },
        {
          "title": "Image Tag",
          "value": "$IMAGE_TAG",
          "short": true
        },
        {
          "title": "Error Message",
          "value": "$message",
          "short": false
        },
        {
          "title": "Workflow Run",
          "value": "<$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID|View Run>",
          "short": false
        }
      ],
      "footer": "cluster-cd-action",
      "ts": $(date +%s)
    }
  ]
}
EOF
)
  
  echo -e "${YELLOW}📢 Sending Slack notification...${NC}"
  if curl -X POST -H 'Content-type: application/json' \
     --data "$payload" \
     "$slack_webhook" > /dev/null 2>&1; then
    echo -e "${GREEN}✅ Slack notification sent successfully${NC}"
  else
    echo -e "${RED}❌ Failed to send Slack notification${NC}"
  fi
}

# Legacy push function for backward compatibility
push() {
  push_with_retry
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
echo "::endgroup::"

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
