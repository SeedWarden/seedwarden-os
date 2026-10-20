#!/bin/bash

set -o errexit -o pipefail
export FORCE_UNSAFE_CONFIGURE=1 # Allows buildroot/tar to run as root user in docker container

# global variables
cur_dir_name=${PWD##*/}
cur_dir=$(pwd)
seedsigner_app_repo="https://github.com/SeedWarden/seedwarden.git"
seedsigner_app_repo_branch="dev"

help()
{
  echo "Usage: build.sh [pi board] [options]
  
  Pi Board: (only one allowed)
  -a, --all         Build for all supported pi boards
      --pi0         Build for pi0 and pi0w
      --pi2         Build for pi2
      --pi02w       Build for pi02w and pi3
      --pi4         Build for pi4 and pi4cmio
  
  Options:
  -h, --help           Display a help screen and quit 
      --dev            Builds developer version of images
      --no-clean       Leave previous build, target, and output files
      --skip-repo      Skip pulling repo, assume rootfs-overlay/opt is populated with app code
      --app-repo       Build image with not official seedsigner github repo
      --app-branch     Build image with repo branch other than default
      --app-commit-id  Build image with specific repo commit id
      --app-dir        Use a local app checkout (e.g. /app, mounted by docker-compose) instead of cloning
      --no-op          All other option ignored and script just hangs to keep container alive"
  exit 2
}

tail_endless() {
  echo "Running 'tail -f /dev/null' to keep script alive"
  tail -f /dev/null
  exit 0
}

# The app lands in ${rootfs_overlay}/opt/src/seedwarden (package only, no tests/tools).
# On the device: PYTHONPATH=/opt/src python3 -m seedwarden

install_app_from_dir() {
  # $1 = app checkout (repo root containing src/seedwarden)
  local src="${1}/src/seedwarden"
  if [ ! -d "${src}" ]; then
    echo "ERROR: ${src} not found (expected the SeedWarden repo root)" >&2
    exit 1
  fi
  rm -fr "${rootfs_overlay}/opt/"
  mkdir -p "${rootfs_overlay}/opt/src"
  cp -r "${src}" "${rootfs_overlay}/opt/src/seedwarden"
  write_version_json "${1}"
}

download_app_repo() {
  local tmp_clone
  tmp_clone="$(mktemp -d)"
  if ! [ -z ${seedsigner_app_repo_commit_id} ]; then
    echo "cloning repo ${seedsigner_app_repo} with commit id ${seedsigner_app_repo_commit_id}"
    git clone "${seedsigner_app_repo}" "${tmp_clone}" || exit
    git -C "${tmp_clone}" reset --hard "${seedsigner_app_repo_commit_id}" || exit
  else
    echo "cloning repo ${seedsigner_app_repo} with branch ${seedsigner_app_repo_branch}"
    git clone --depth 1 -b "${seedsigner_app_repo_branch}" "${seedsigner_app_repo}" "${tmp_clone}" || exit
  fi
  install_app_from_dir "${tmp_clone}"
  rm -rf "${tmp_clone}"
}

write_version_json() {
  # Minimal build info for the app: {"commit": ..., "describe": ...}
  local app_repo="${1}" commit="unknown" describe="unknown"
  if [ -d "${app_repo}/.git" ] || [ -f "${app_repo}/.git" ]; then
    git config --global --add safe.directory "$(cd "${app_repo}" && pwd)"
    commit="$(git -C "${app_repo}" rev-parse HEAD 2>/dev/null || echo unknown)"
    describe="$(git -C "${app_repo}" describe --tags --always --dirty 2>/dev/null || echo unknown)"
  fi
  printf '{"commit": "%s", "describe": "%s"}\n' "${commit}" "${describe}" \
    > "${rootfs_overlay}/opt/src/seedwarden/version.json"
  cat "${rootfs_overlay}/opt/src/seedwarden/version.json"
}

delete_unnecessary_files() {
  find "${rootfs_overlay}/opt" -name '__pycache__' -type d -prune -exec rm -rf {} +
  find "${rootfs_overlay}/opt" -name '*.pyc' -delete
}

build_image() {
  # arguments: $1 - config name, $2 clean/no-clean - allows for, $3 skip-repo

  # Variables
  config_name="${1:-pi0}"
  config_dir="./${config_name}"
  rootfs_overlay="./rootfs-overlay"
  config_file="${config_dir}/configs/pi0"
  build_dir="${cur_dir}/../output"
  build2_dir="${cur_dir}/../../output"
  image_dir="${cur_dir}/../images"

  if [ ! -d "${config_dir}" ]; then
    # config does not exists
    echo "config ${config_name} not found"
    exit 1
  fi
  
  if [ "${2}" != "no-clean" ]; then
  
    # remove previous build dir
    rm -rf "${build_dir}"
    mkdir -p "${build_dir}"
    
  fi
  
  if [ "${3}" != "skip-repo" ]; then
    download_app_repo
  fi

  # Both run unconditionally so --skip-repo builds get the same treatment. Order
  # matters: write_version_json needs the .git/ and tools/ that the other removes.
  write_version_json
  delete_unnecessary_files

  # Setup external tree
  #make BR2_EXTERNAL="../${config_dir}/" O="${build_dir}" -C ./buildroot/ #2> /dev/null > /dev/null

  PATH="/usr/lib/ccache:${PATH}" make BR2_EXTERNAL="../${config_dir}/" O="${build_dir}" -C ./buildroot/ ${config_name}_defconfig
  cd "${build_dir}"
  PATH="/usr/lib/ccache:${PATH}" make
  
  # if successful, mv seedsigner_os.img image to /images
  # rename to image to include branch name and config name, then compress
  
  seedsigner_os_image_output="${image_dir}/seedwarden_os.${seedsigner_app_repo_branch}.${config_name}.img"
  if ! [ -z ${seedsigner_app_repo_commit_id} ]; then
    # use commit id instead of branch name if it is set
    seedsigner_os_image_output="${image_dir}/seedwarden_os.${seedsigner_app_repo_commit_id}.${config_name}.img"
  fi
  
  if [ -f "${build_dir}/images/seedwarden_os.img" ] && [ -d "${image_dir}" ]; then
    mv -f "${build_dir}/images/seedwarden_os.img" "${seedsigner_os_image_output}"
    sha256sum "${seedsigner_os_image_output}"
  fi
  
  cd - > /dev/null # return to previous working directory quietly
}

###
### Gather Arguments passed into build.sh script
###

VALID_ARGUMENTS=$# # Returns the count of arguments that are in short or long options

if [ "$VALID_ARGUMENTS" -eq 0 ]; then
  help
fi

PARAMS=""
ARCH_CNT=0
while (( "$#" )); do
  case "$1" in
  -a|--all)
    ALL_FLAG=0; ((ARCH_CNT=ARCH_CNT+1)); shift
    ;;
  -h|--help)
    HELP_FLAG=0; shift
    ;;
  --pi0)
    PI0_FLAG=0; ((ARCH_CNT=ARCH_CNT+1)); shift
    ;;
  --pi2)
    PI2_FLAG=0; ((ARCH_CNT=ARCH_CNT+1)); shift
    ;;
  --pi02w)
    PI02W_FLAG=0; ((ARCH_CNT=ARCH_CNT+1)); shift
    ;;
  --pi4)
    PI4_FLAG=0; ((ARCH_CNT=ARCH_CNT+1)); shift
    ;;
  --no-clean)
    NOCLEAN=0; shift
    ;;
  --skip-repo)
    SKIPREPO=0; shift
    ;;
  --no-op)
    NO_OP=0; shift
    ;;
  --dev)
    DEVBUILD=0; shift
    ;;
  --app-repo=*)
    APP_REPO=$(echo "${1}" | cut -d "=" -f2-); shift
    ;;
  --app-branch=*)
    APP_BRANCH=$(echo "${1}" | cut -d "=" -f2-); shift
    ;;
  --app-dir=*)
    APP_DIR=$(echo "${1}" | cut -d "=" -f2-); shift
    ;;
  --app-commit-id=*)
    APP_COMMITID=$(echo "${1}" | cut -d "=" -f2-); shift
    ;;
  -*|--*=) # unsupported flags
    echo "Error: Unsupported flag $1" >&2
    help
    exit 1
    ;;
  *) # unsupported flags
    echo "Error: Unsupported argument $1" >&2
    help
    exit 1
    ;;
  esac
done

# When no arguments, display help
if ! [ -z ${HELP_FLAG} ]; then
  help
fi

# Only allow 1 architecture related argument flag
if [ $ARCH_CNT -gt 1 ]; then
  echo "Invalid number of architecture arguments" >&2
  exit 3
fi

# if no-op then hang endlessly
if ! [ -z $NO_OP ]; then
  tail_endless
  exit 0
fi

# Check for --no-clean argument to pass clean/no-clean to build_image function
if [ -z $NOCLEAN ]; then
  CLEAN_ARG="clean"
else
  CLEAN_ARG="no-clean"
fi

# Check for --no-clean argument to pass clean/no-clean to build_image function
if ! [ -z $SKIPREPO ]; then
  SKIPREPO_ARG="skip-repo"
else
  SKIPREPO_ARG="no-skip-repo"
fi

echo $SKIPREPO_ARG

# Check for --dev argument to pass to build_image function
DEVARG=""
if ! [ -z $DEVBUILD ]; then
  DEVARG="-dev"
fi

# check for custom app repo
if ! [ -z ${APP_REPO} ]; then
  seedsigner_app_repo="${APP_REPO}"
fi

# check for custom app branch
if ! [ -z ${APP_BRANCH} ]; then
  seedsigner_app_repo_branch="${APP_BRANCH}"
fi

# check for custom app branch
if ! [ -z ${APP_COMMITID} ]; then
  seedsigner_app_repo_commit_id="${APP_COMMITID}"
fi

###
### Run build_image function based on input arguments
###

# Build All Architectures
if ! [ -z ${ALL_FLAG} ]; then
  build_image "pi0${DEVARG}" "clean" "${SKIPREPO_ARG}"
  build_image "pi02w${DEVARG}" "clean" "skip-repo"
  build_image "pi2${DEVARG}" "clean" "skip-repo"
  build_image "pi4${DEVARG}" "clean" "skip-repo"
fi

# Build only for pi0, pi0w, and pi1
if ! [ -z ${PI0_FLAG} ]; then
  build_image "pi0${DEVARG}" "${CLEAN_ARG}" "${SKIPREPO_ARG}"
fi

# Build only for pi2
if ! [ -z ${PI2_FLAG} ]; then
  build_image "pi2${DEVARG}" "${CLEAN_ARG}" "${SKIPREPO_ARG}"
fi

# build for pi02w
if ! [ -z ${PI02W_FLAG} ]; then
  build_image "pi02w${DEVARG}" "${CLEAN_ARG}" "${SKIPREPO_ARG}"
fi

# build for pi4
if ! [ -z ${PI4_FLAG} ]; then
  build_image "pi4${DEVARG}" "${CLEAN_ARG}" "${SKIPREPO_ARG}"
fi

exit 0
