#!/bin/zsh
# Copies the helper into the app and signs it. Xcode runs this after it builds the app and
# before it signs the bundle, so the app's signature seals a helper that is already signed.
# launchd starts the helper from Contents/MacOS, where the daemon's property list points.
set -euo pipefail

helper="$PROJECT_DIR/backend/target/$AIRFLOW_BACKEND_PROFILE/AirFlowHelper"
destination="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/MacOS/AirFlowHelper"
cp -f "$helper" "$destination"

identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
flags=(--force --sign "$identity" --identifier com.kevster.airflow.helper)
[[ "${ENABLE_HARDENED_RUNTIME:-NO}" == YES ]] && flags+=(--options runtime)
# A release signed by a developer needs a secure timestamp before Apple will notarize it.
if [[ "$CONFIGURATION" == Release && "$identity" != "-" ]]; then
    flags+=(--timestamp)
else
    flags+=(--timestamp=none)
fi
codesign "${flags[@]}" "$destination"
