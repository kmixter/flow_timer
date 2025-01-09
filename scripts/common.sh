# Common variables
BUILD_DIR="build"
RELEASE_DIR="release"

# Common functions
prepare_build() {
    echo "Preparing build directory..."
    mkdir -p $BUILD_DIR
    mkdir -p $RELEASE_DIR
}

clean_build() {
    echo "Cleaning build directory..."
    rm -rf $BUILD_DIR/*
}

verify_git_status() {
    if ! $FORCE && ! git diff-index --quiet HEAD --; then
        echo "There are uncommitted changes. Please commit or stash them before releasing."
        exit 1
    fi

    if ! git describe --tags --exact-match 2>/dev/null; then
        echo "No tag found on the current commit. Please tag the commit with a version like 'release-x.y.z'."
        exit 1
    fi

    TAG=$(git describe --tags --exact-match 2>/dev/null)

    if [[ $? -ne 0 ]]; then
        echo "No tag found on the current commit. Please tag the commit with a version like 'release-x.y.z'."
        exit 1
    fi

    if [[ $TAG =~ ^release-([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        VERSION=${BASH_REMATCH[1]}
    else
        echo "Tag format is incorrect. Please use 'release-x.y.z'."
        exit 1
    fi
}

# ...other common functions...
