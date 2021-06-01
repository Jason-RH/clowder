#!/bin/bash
set -e

##########################################################################
# This is a copypasta from:
# https://github.com/app-sre/deployment-validation-operator/blob/master/build_catalog.sh
#
##########################################################################

function log ()
{
  echo "######## $1 ########"
}

count=0
for var in BUNDLE_IMAGE \
           CATALOG_IMAGE \
           QUAY_USER \
           QUAY_TOKEN
do
  if [ ! "${!var}" ]; then
    log "$var is not set"
    count=$((count + 1))
  fi
done

[ $count -gt 0 ] && exit 1

num_commits=$(git rev-list $(git rev-list --max-parents=0 HEAD)..HEAD --count)
current_commit=$(git rev-parse --short=7 HEAD)
version="0.1.$num_commits-git$current_commit"
opm_version="1.14.1"

# Login to docker
docker_cmd="podman"
AUTH_CONF_DIR="$(pwd)/.podman"
mkdir -p $AUTH_CONF_DIR
export REGISTRY_AUTH_FILE="$AUTH_CONF_DIR/auth.json"
$docker_cmd login -u="$QUAY_USER" -p="$QUAY_TOKEN" quay.io

# Find the CSV version from the previous bundle
log "Pulling latest bundle image $BUNDLE_IMAGE"
$docker_cmd pull $BUNDLE_IMAGE:latest && exists=1 || exists=0

if [ $exists -eq 1 ]; then
  log "Extracting previous version from bundle image"
  $docker_cmd create --name="tmp_$$" $BUNDLE_IMAGE:latest sh
  tmp_dir=$(mktemp -d -t sa-XXXXXXXXXX)
  pushd $tmp_dir
    $docker_cmd export tmp_$$ | tar -xf -
    prev_version=`find . -name *.clusterserviceversion.* | xargs cat - | python3 -c 'import sys,yaml; print(yaml.safe_load(sys.stdin.read())["spec"]["version"])'`
    if [[ "$prev_version" == "" ]]; then
      log "Unable to find previous bundle version"
      exit 1
    fi
    log "Found previous bundle version $prev_version"
  popd
  rm -rf $tmp_dir
  $docker_cmd rm tmp_$$
fi

# Build/push the new bundle
log "Creating bundle $BUNDLE_IMAGE:$current_commit"
if [[ $prev_version != "" ]]; then
  export REPLACE_VERSION=$prev_version
fi
export BUNDLE_IMAGE_TAG=$current_commit
export VERSION=$version
mkdir -p ./bin
curl -L https://github.com/operator-framework/operator-sdk/releases/download/v1.8.0/operator-sdk_linux_amd64 -o ./operator-sdk
curl -L https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv4.1.3/kustomize_v4.1.3_linux_amd64.tar.gz | tar xzf - -O > bin/kustomize
chmod +x ./operator-sdk
chmod +x ./bin/kustomize
export PATH=$PATH:.
make bundle
make bundle-build
$docker_cmd tag $BUNDLE_IMAGE:$current_commit $BUNDLE_IMAGE:latest

log "Pushing the bundle $BUNDLE_IMAGE:$current_commit to repository"
$docker_cmd push $BUNDLE_IMAGE:$current_commit
# Do not push the latest tag here.  If there is a problem creating the catalog then
# pushing the latest tag here will mean subsequent runs will be extracting a bundle
# version that isn't referenced in the catalog.  This will result in all future
# catalog creation failing to be created.

# Download opm build
curl -L https://github.com/operator-framework/operator-registry/releases/download/v$opm_version/linux-amd64-opm -o ./opm
chmod u+x ./opm

# Create/push a new catalog via opm
log "Pulling existing latest catalog $CATALOG_IMAGE"
$docker_cmd pull $CATALOG_IMAGE:latest && exists=1 || exists=0
if [ $exists -eq 1 ]; then
  from_arg="--from-index $CATALOG_IMAGE:latest"
fi

if [[ "$from_arg" == "" ]]; then
  log "Creating new catalog $CATALOG_IMAGE"
else
  log "Updating existing catalog $CATALOG_IMAGE"
fi

./opm index add --bundles $BUNDLE_IMAGE:$current_commit $from_arg --tag $CATALOG_IMAGE:$current_commit --build-tool docker
if [ $? -ne 0 ]; then
  exit 1
fi
$docker_cmd tag $CATALOG_IMAGE:$current_commit $CATALOG_IMAGE:latest

log "Pushing catalog $CATALOG_IMAGE:$current_commit to repository"
$docker_cmd push $CATALOG_IMAGE:$current_commit

# Only put the latest tags once everything else has succeeded
log "Pushing latest tags for $BUNDLE_IMAGE and $CATALOG_IMAGE"
$docker_cmd push $CATALOG_IMAGE:latest
$docker_cmd push $BUNDLE_IMAGE:latest
