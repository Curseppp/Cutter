#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_NAME="BackgroundAway"
APP_DIR="${PROJECT_DIR}/dist/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"

cd "${PROJECT_DIR}"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

if [[ "${APP_DIR}" != "${PROJECT_DIR}/dist/${APP_NAME}.app" ]]; then
    echo "Некорректный путь приложения" >&2
    exit 1
fi

rm -rf "${APP_DIR}"
mkdir -p "${CONTENTS_DIR}/MacOS" "${CONTENTS_DIR}/Resources"
cp "${BIN_DIR}/${APP_NAME}" "${CONTENTS_DIR}/MacOS/${APP_NAME}"
cp "${PROJECT_DIR}/Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"

codesign --force --deep --sign - "${APP_DIR}"

echo "Готово: ${APP_DIR}"
