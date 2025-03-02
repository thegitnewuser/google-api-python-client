#!/bin/bash
# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


# `-e` enables the script to automatically fail when a command fails
# `-o pipefail` sets the exit code to the rightmost comment to exit with a non-zero
set -eo pipefail
# Enables `**` to include files nested inside sub-folders
shopt -s globstar

cd github/google-api-python-client

# Run periodic samples tests at latest release
if [[ $KOKORO_BUILD_ARTIFACTS_SUBDIR = *"periodic"* ]]; then
    LATEST_RELEASE=$(git describe --abbrev=0 --tags)
    git checkout $LATEST_RELEASE
fi

# Disable buffering, so that the logs stream through.
export PYTHONUNBUFFERED=1

# Debug: show build environment
env | grep KOKORO

# Install nox
python3.6 -m pip install --upgrade --quiet nox

# Use secrets acessor service account to get secrets
if [[ -f "${KOKORO_GFILE_DIR}/secrets_viewer_service_account.json" ]]; then
    gcloud auth activate-service-account \
	   --key-file="${KOKORO_GFILE_DIR}/secrets_viewer_service_account.json" \
	   --project="cloud-devrel-kokoro-resources"
fi

# This script will create 3 files:
# - testing/test-env.sh
# - testing/service-account.json
# - testing/client-secrets.json
./scripts/decrypt-secrets.sh

source ./testing/test-env.sh
export GOOGLE_APPLICATION_CREDENTIALS=$(pwd)/testing/service-account.json

# For cloud-run session, we activate the service account for gcloud sdk.
gcloud auth activate-service-account \
       --key-file "${GOOGLE_APPLICATION_CREDENTIALS}"

export GOOGLE_CLIENT_SECRETS=$(pwd)/testing/client-secrets.json

echo -e "\n******************** TESTING PROJECTS ********************"

# Switch to 'fail at end' to allow all tests to complete before exiting.
set +e
# Use RTN to return a non-zero value if the test fails.
RTN=0
ROOT=$(pwd)
# Find all requirements.txt in the samples directory (may break on whitespace).
for file in samples/**/requirements.txt; do
    cd "$ROOT"
    # Navigate to the project folder.
    file=$(dirname "$file")
    cd "$file"

    echo "------------------------------------------------------------"
    echo "- testing $file"
    echo "------------------------------------------------------------"

    # Use nox to execute the tests for the project.
    python3.6 -m nox -s "$RUN_TESTS_SESSION"
    EXIT=$?

    # If this is a periodic build, send the test log to the Build Cop Bot.
    # See https://github.com/googleapis/repo-automation-bots/tree/master/packages/buildcop.
    if [[ $KOKORO_BUILD_ARTIFACTS_SUBDIR = *"periodic"* ]]; then
      chmod +x $KOKORO_GFILE_DIR/linux_amd64/buildcop
      $KOKORO_GFILE_DIR/linux_amd64/buildcop
    fi

    if [[ $EXIT -ne 0 ]]; then
      RTN=1
      echo -e "\n Testing failed: Nox returned a non-zero exit code. \n"
    else
      echo -e "\n Testing completed.\n"
    fi

done
cd "$ROOT"

# Workaround for Kokoro permissions issue: delete secrets
rm testing/{test-env.sh,client-secrets.json,service-account.json}

exit "$RTN"