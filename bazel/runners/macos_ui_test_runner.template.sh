#!/bin/bash

set -euo pipefail

if [[ -n "${TEST_PREMATURE_EXIT_FILE:-}" ]]; then
  touch "$TEST_PREMATURE_EXIT_FILE"
fi

basename_without_extension() {
  local filename
  filename=$(basename "$1")
  echo "${filename%.*}"
}

escape() {
  local escaped
  escaped=${1//&/&amp;}
  escaped=${escaped//</&lt;}
  escaped=${escaped//>/&gt;}
  escaped=${escaped//'"'/&quot;}
  echo "$escaped"
}

read_plist_string() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$2"
}

set_plist_string() {
  plutil -replace "$1" -string "$2" "$3"
}

set_plist_bool() {
  plutil -replace "$1" -bool "$2" "$3"
}

binary_arch() {
  lipo -archs "$1" | awk '{print $1}'
}

thin_binary_to_arch() {
  local binary_path="$1"
  local target_arch="$2"
  local current_archs
  local thinned_binary

  current_archs=$(lipo -archs "$binary_path")
  if [[ "$current_archs" == "$target_arch" ]]; then
    return
  fi

  thinned_binary="${binary_path}.thinned"
  rm -f "$thinned_binary"
  lipo "$binary_path" -thin "$target_arch" -output "$thinned_binary"
  mv "$thinned_binary" "$binary_path"
  chmod 755 "$binary_path"
}

copy_bundle() {
  local source_path="$1"
  local destination_dir="$2"

  if [[ "$source_path" == *.app || "$source_path" == *.xctest ]]; then
    cp -R "$source_path" "$destination_dir"
  else
    unzip -qq -d "$destination_dir" "$source_path"
  fi
}

copy_framework_if_exists() {
  local source_path="$1"
  local destination_dir="$2"
  local destination_path

  if [[ -d "$source_path" ]]; then
    destination_path="$destination_dir/$(basename "$source_path")"
    if [[ -e "$destination_path" ]]; then
      return
    fi
    cp -R "$source_path" "$destination_dir"
  fi
}

copy_dylib_if_exists() {
  local source_path="$1"
  local destination_dir="$2"
  local destination_path

  if [[ -f "$source_path" ]]; then
    destination_path="$destination_dir/$(basename "$source_path")"
    if [[ -e "$destination_path" ]]; then
      return
    fi
    cp "$source_path" "$destination_dir"
  fi
}

copy_xcode_framework_if_exists() {
  local framework_name="$1"
  local destination_dir="$2"
  local framework_root

  for framework_root in \
    "$LIBRARIES_PATH/Frameworks" \
    "$LIBRARIES_PATH/PrivateFrameworks" \
    "$XCODE_SHARED_FRAMEWORKS_PATH"
  do
    copy_framework_if_exists "$framework_root/$framework_name" "$destination_dir"
  done
}

is_processed_xcode_dependency() {
  local key="$1"
  grep -Fqx "$key" "$PROCESSED_XCODE_DEPENDENCIES_FILE"
}

mark_processed_xcode_dependency() {
  echo "$1" >> "$PROCESSED_XCODE_DEPENDENCIES_FILE"
}

framework_binary_path() {
  local framework_path="$1"
  local framework_name

  framework_name=$(basename "$framework_path" .framework)
  echo "$framework_path/$framework_name"
}

resolve_xcode_dependency_path() {
  local dependency_path="$1"
  local framework_name
  local dylib_name
  local search_root

  if [[ "$dependency_path" == @rpath/*.framework/* ]]; then
    framework_name=$(echo "$dependency_path" | sed -E 's#^@rpath/([^/]+\.framework)/.*#\1#')
    for search_root in \
      "$LIBRARIES_PATH/Frameworks" \
      "$LIBRARIES_PATH/PrivateFrameworks" \
      "$XCODE_SHARED_FRAMEWORKS_PATH"
    do
      if [[ -d "$search_root/$framework_name" ]]; then
        echo "$search_root/$framework_name"
        return 0
      fi
    done
  elif [[ "$dependency_path" == @rpath/*.dylib ]]; then
    dylib_name="${dependency_path##*/}"
    for search_root in \
      "$DEVELOPER_PATH/usr/lib" \
      "$LIBRARIES_PATH/Frameworks" \
      "$LIBRARIES_PATH/PrivateFrameworks" \
      "$XCODE_SHARED_FRAMEWORKS_PATH"
    do
      if [[ -f "$search_root/$dylib_name" ]]; then
        echo "$search_root/$dylib_name"
        return 0
      fi
    done
  fi

  return 1
}

copy_xcode_dependency_closure() {
  local binary_path="$1"
  local destination_dir="$2"
  local dependency_path
  local resolved_path
  local dependency_key
  local copied_path

  if [[ ! -f "$binary_path" ]]; then
    return
  fi

  while IFS= read -r dependency_path; do
    [[ "$dependency_path" == @rpath/* ]] || continue

    if ! resolved_path=$(resolve_xcode_dependency_path "$dependency_path"); then
      continue
    fi

    dependency_key="$destination_dir::$resolved_path"
    if is_processed_xcode_dependency "$dependency_key"; then
      continue
    fi
    mark_processed_xcode_dependency "$dependency_key"

    if [[ -d "$resolved_path" ]]; then
      copy_framework_if_exists "$resolved_path" "$destination_dir"
      copied_path="$destination_dir/$(basename "$resolved_path")"
      copy_xcode_dependency_closure "$(framework_binary_path "$copied_path")" "$destination_dir"
    else
      copy_dylib_if_exists "$resolved_path" "$destination_dir"
      copied_path="$destination_dir/$(basename "$resolved_path")"
      copy_xcode_dependency_closure "$copied_path" "$destination_dir"
    fi
  done < <(otool -L "$binary_path" | tail -n +2 | awk '{print $1}')
}

populate_xcode_dependency_closure() {
  local destination_dir="$1"
  local framework_path
  local dylib_path

  while IFS= read -r framework_path; do
    copy_xcode_dependency_closure "$(framework_binary_path "$framework_path")" "$destination_dir"
  done < <(find "$destination_dir" -maxdepth 1 -type d -name "*.framework" | sort)

  while IFS= read -r dylib_path; do
    copy_xcode_dependency_closure "$dylib_path" "$destination_dir"
  done < <(find "$destination_dir" -maxdepth 1 -type f -name "*.dylib" | sort)
}

codesign_item() {
  codesign --force --timestamp=none --sign - "$1" >/dev/null 2>&1
}

codesign_item_with_entitlements() {
  local item_path="$1"
  local entitlements_path="$2"

  codesign --force --timestamp=none --sign - --entitlements "$entitlements_path" "$item_path" >/dev/null 2>&1
}

BAZEL_XCTESTRUN_TEMPLATE=%(xctestrun_template)s

TEST_TMP_DIR="$(mktemp -d "${TEST_TMPDIR:-${TMPDIR:-/tmp}}/test_tmp_dir.XXXXXX")"
PROCESSED_XCODE_DEPENDENCIES_FILE="$TEST_TMP_DIR/processed-xcode-dependencies.txt"
touch "$PROCESSED_XCODE_DEPENDENCIES_FILE"
if [[ -z "${NO_CLEAN:-}" ]]; then
  trap 'rm -rf "${TEST_TMP_DIR}"' ERR EXIT
else
  echo "note: keeping test dir around at: ${TEST_TMP_DIR}"
fi

TEST_BUNDLE_PATH="%(test_bundle_path)s"
TEST_BUNDLE_NAME=$(basename_without_extension "$TEST_BUNDLE_PATH")
copy_bundle "$TEST_BUNDLE_PATH" "$TEST_TMP_DIR"
chmod -R 777 "$TEST_TMP_DIR/$TEST_BUNDLE_NAME.xctest"

TEST_HOST_PATH="%(test_host_path)s"
if [[ -z "$TEST_HOST_PATH" ]]; then
  echo "error: macOS UI tests require a test host app" >&2
  exit 1
fi

copy_bundle "$TEST_HOST_PATH" "$TEST_TMP_DIR"
# When the test host is a zip, the app inside may have a different name
# (bundle_name vs Bazel target name). Discover the actual .app directory.
TEST_HOST_APP=$(find "$TEST_TMP_DIR" -maxdepth 1 -name "*.app" -print -quit)
if [[ -z "$TEST_HOST_APP" ]]; then
  echo "error: no .app bundle found after extracting test host" >&2
  exit 1
fi
TEST_HOST_NAME=$(basename_without_extension "$TEST_HOST_APP")
chmod -R 777 "$TEST_HOST_APP"

TEST_BUNDLE_INFO_PLIST="$TEST_TMP_DIR/$TEST_BUNDLE_NAME.xctest/Contents/Info.plist"
TEST_BUNDLE_ID=$(read_plist_string "CFBundleIdentifier" "$TEST_BUNDLE_INFO_PLIST")

DEVELOPER_DIR=$(xcode-select -p)
XCODE_CONTENTS_DIR="${DEVELOPER_DIR%/Developer}"
DEVELOPER_PATH="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer"
LIBRARIES_PATH="$DEVELOPER_PATH/Library"
XCODE_SHARED_FRAMEWORKS_PATH="$XCODE_CONTENTS_DIR/SharedFrameworks"
RUNNER_APP_NAME="$TEST_BUNDLE_NAME-Runner"
RUNNER_APP="$RUNNER_APP_NAME.app"
RUNNER_APP_DESTINATION="$TEST_TMP_DIR/$RUNNER_APP"
RUNNER_BUNDLE_ID="$TEST_BUNDLE_ID.xctrunner"

cp -R "$LIBRARIES_PATH/Xcode/Agents/XCTRunner.app" "$RUNNER_APP_DESTINATION"
chmod -R 777 "$RUNNER_APP_DESTINATION"
mv "$RUNNER_APP_DESTINATION/Contents/MacOS/XCTRunner" \
  "$RUNNER_APP_DESTINATION/Contents/MacOS/$RUNNER_APP_NAME"
TEST_BUNDLE_BINARY="$TEST_TMP_DIR/$TEST_BUNDLE_NAME.xctest/Contents/MacOS/$TEST_BUNDLE_NAME"
RUNNER_BINARY="$RUNNER_APP_DESTINATION/Contents/MacOS/$RUNNER_APP_NAME"
thin_binary_to_arch "$RUNNER_BINARY" "$(binary_arch "$TEST_BUNDLE_BINARY")"

/usr/libexec/PlistBuddy -c "Set :CFBundleName $RUNNER_APP_NAME" \
  "$RUNNER_APP_DESTINATION/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $RUNNER_APP_NAME" \
  "$RUNNER_APP_DESTINATION/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $RUNNER_BUNDLE_ID" \
  "$RUNNER_APP_DESTINATION/Contents/Info.plist"

RUNNER_PLUGINS_DIR="$RUNNER_APP_DESTINATION/Contents/PlugIns"
RUNNER_FRAMEWORKS_DIR="$RUNNER_APP_DESTINATION/Contents/Frameworks"
mkdir -p "$RUNNER_PLUGINS_DIR" "$RUNNER_FRAMEWORKS_DIR"

mv "$TEST_TMP_DIR/$TEST_BUNDLE_NAME.xctest" \
  "$RUNNER_PLUGINS_DIR/$TEST_BUNDLE_NAME.xctest"
chmod -R 777 "$RUNNER_PLUGINS_DIR/$TEST_BUNDLE_NAME.xctest"
TEST_BUNDLE_FRAMEWORKS_DIR="$RUNNER_PLUGINS_DIR/$TEST_BUNDLE_NAME.xctest/Contents/Frameworks"
mkdir -p "$TEST_BUNDLE_FRAMEWORKS_DIR"
TEST_BUNDLE_INFO_PLIST="$RUNNER_PLUGINS_DIR/$TEST_BUNDLE_NAME.xctest/Contents/Info.plist"

# Match the Info.plist shape Xcode emits for UI test bundles so testmanagerd
# consistently recognizes the bundle as a UI test product.
set_plist_string CFBundleDevelopmentRegion en "$TEST_BUNDLE_INFO_PLIST"
set_plist_string CFBundleInfoDictionaryVersion 6.0 "$TEST_BUNDLE_INFO_PLIST"
set_plist_string CFBundlePackageType BNDL "$TEST_BUNDLE_INFO_PLIST"
set_plist_string CFBundleShortVersionString 1.0 "$TEST_BUNDLE_INFO_PLIST"
set_plist_string CFBundleVersion 1 "$TEST_BUNDLE_INFO_PLIST"
set_plist_string NSHumanReadableCopyright "Copyright ©. All rights reserved." "$TEST_BUNDLE_INFO_PLIST"
set_plist_bool XCTContainsUITests YES "$TEST_BUNDLE_INFO_PLIST"

for framework in XCTest.framework Testing.framework; do
  copy_xcode_framework_if_exists "$framework" "$RUNNER_FRAMEWORKS_DIR"
  copy_xcode_framework_if_exists "$framework" "$TEST_BUNDLE_FRAMEWORKS_DIR"
done

for framework in XCTAutomationSupport.framework XCTestCore.framework XCTestSupport.framework XCUnit.framework; do
  copy_xcode_framework_if_exists "$framework" "$RUNNER_FRAMEWORKS_DIR"
  copy_xcode_framework_if_exists "$framework" "$TEST_BUNDLE_FRAMEWORKS_DIR"
done

if [[ -d "$LIBRARIES_PATH/Frameworks/XCUIAutomation.framework" ]]; then
  copy_framework_if_exists "$LIBRARIES_PATH/Frameworks/XCUIAutomation.framework" "$RUNNER_FRAMEWORKS_DIR"
  copy_framework_if_exists "$LIBRARIES_PATH/Frameworks/XCUIAutomation.framework" "$TEST_BUNDLE_FRAMEWORKS_DIR"
else
  copy_framework_if_exists "$LIBRARIES_PATH/PrivateFrameworks/XCUIAutomation.framework" "$RUNNER_FRAMEWORKS_DIR"
  copy_framework_if_exists "$LIBRARIES_PATH/PrivateFrameworks/XCUIAutomation.framework" "$TEST_BUNDLE_FRAMEWORKS_DIR"
fi

for dylib in libXCTestBundleInject.dylib libXCTestSwiftSupport.dylib lib_TestingInterop.dylib; do
  copy_dylib_if_exists "$DEVELOPER_PATH/usr/lib/$dylib" "$RUNNER_FRAMEWORKS_DIR"
  copy_dylib_if_exists "$DEVELOPER_PATH/usr/lib/$dylib" "$TEST_BUNDLE_FRAMEWORKS_DIR"
done

populate_xcode_dependency_closure "$RUNNER_FRAMEWORKS_DIR"
populate_xcode_dependency_closure "$TEST_BUNDLE_FRAMEWORKS_DIR"

if [[ -d "$RUNNER_FRAMEWORKS_DIR" ]]; then
  while IFS= read -r framework_path; do
    codesign_item "$framework_path"
  done < <(find "$RUNNER_FRAMEWORKS_DIR" -type d -name "*.framework" -prune | sort)

  while IFS= read -r dylib_path; do
    codesign_item "$dylib_path"
  done < <(find "$RUNNER_FRAMEWORKS_DIR" -type f -name "*.dylib" | sort)
fi

if [[ -d "$TEST_BUNDLE_FRAMEWORKS_DIR" ]]; then
  while IFS= read -r framework_path; do
    codesign_item "$framework_path"
  done < <(find "$TEST_BUNDLE_FRAMEWORKS_DIR" -type d -name "*.framework" -prune | sort)

  while IFS= read -r dylib_path; do
    codesign_item "$dylib_path"
  done < <(find "$TEST_BUNDLE_FRAMEWORKS_DIR" -type f -name "*.dylib" | sort)
fi

RUNNER_ENTITLEMENTS="$TEST_TMP_DIR/runner-entitlements.plist"
cat > "$RUNNER_ENTITLEMENTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key>
  <false/>
  <key>com.apple.security.get-task-allow</key>
  <true/>
  <key>com.apple.security.network.client</key>
  <true/>
  <key>com.apple.security.temporary-exception.files.absolute-path.read-only</key>
  <array>
    <string>/</string>
  </array>
  <key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
  <array>
    <string>com.apple.testmanagerd</string>
    <string>com.apple.dt.testmanagerd.runner</string>
    <string>com.apple.coresymbolicationd</string>
    <string>com.apple.coredevice.version</string>
    <string>com.apple.coredevice.service</string>
    <string>com.apple.remoted</string>
  </array>
  <key>com.apple.security.temporary-exception.mach-lookup.local-name</key>
  <array>
    <string>com.apple.axserver</string>
  </array>
  <key>com.apple.security.temporary-exception.sbpl</key>
  <array>
    <string>(allow hid-control)</string>
    <string>(allow signal)</string>
  </array>
</dict>
</plist>
EOF

codesign_item "$RUNNER_PLUGINS_DIR/$TEST_BUNDLE_NAME.xctest"
codesign_item_with_entitlements "$RUNNER_APP_DESTINATION" "$RUNNER_ENTITLEMENTS"

readonly test_binary="$RUNNER_PLUGINS_DIR/$TEST_BUNDLE_NAME.xctest/Contents/MacOS/$TEST_BUNDLE_NAME"

XCTESTRUN_TEST_BUNDLE_PATH="__TESTHOST__/Contents/PlugIns/$TEST_BUNDLE_NAME.xctest"
XCTESTRUN_TEST_HOST_PATH="__TESTROOT__/$RUNNER_APP"
XCTESTRUN_TARGET_APP_PATH="__TESTROOT__/$TEST_HOST_NAME.app"
XCTESTRUN_TEST_HOST_BASED=true
XCTESTRUN_TEST_HOST_BUNDLE_IDENTIFIER="$RUNNER_BUNDLE_ID"
XCTESTRUN_TEST_HOST_BINARY="__TESTROOT__/$TEST_HOST_NAME.app/Contents/MacOS/$TEST_HOST_NAME"
XCTESTRUN_DYLD_FRAMEWORK_PATH="__TESTHOST__/Contents/Frameworks:__PLATFORMS__/MacOSX.platform/Developer/Library/Frameworks:__PLATFORMS__/MacOSX.platform/Developer/Library/PrivateFrameworks"
XCTESTRUN_DYLD_LIBRARY_PATH="__TESTHOST__/Contents/Frameworks:__PLATFORMS__/MacOSX.platform/Developer/usr/lib"

TEST_ENV="%(test_env)s"
readonly profraw="$TEST_TMP_DIR/coverage.profraw"
if [[ "${COVERAGE:-0}" -eq 1 ]]; then
  readonly profile_env="LLVM_PROFILE_FILE=$profraw"
  if [[ -n "$TEST_ENV" ]]; then
    TEST_ENV="$TEST_ENV,$profile_env"
  else
    TEST_ENV="$profile_env"
  fi
fi

XCTESTRUN_ENV=""
for SINGLE_TEST_ENV in ${TEST_ENV//,/ }; do
  IFS== read -r key value <<< "$SINGLE_TEST_ENV"
  XCTESTRUN_ENV+="<key>$(escape "$key")</key><string>$(escape "$value")</string>"
done

# Expose the workspace root so tests can locate data files when #filePath
# produces relative paths (Bazel compiles with relative source paths).
if [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
  XCTESTRUN_ENV+="<key>CLIPKITTY_PROJECT_ROOT</key><string>$(escape "$BUILD_WORKSPACE_DIRECTORY")</string>"
fi

TEST_FILTER="%(test_filter)s"
XCTESTRUN_SKIP_TEST_SECTION=""
XCTESTRUN_ONLY_TEST_SECTION=""

if [[ -n "${TESTBRIDGE_TEST_ONLY:-}" || -n "${TEST_FILTER:-}" ]]; then
  if [[ -n "${TESTBRIDGE_TEST_ONLY:-}" && -n "${TEST_FILTER:-}" ]]; then
    ALL_TESTS="$TESTBRIDGE_TEST_ONLY,$TEST_FILTER"
  elif [[ -n "${TESTBRIDGE_TEST_ONLY:-}" ]]; then
    ALL_TESTS="$TESTBRIDGE_TEST_ONLY"
  else
    ALL_TESTS="$TEST_FILTER"
  fi

  OLD_IFS=$IFS
  IFS=","
  for TEST_NAME in $ALL_TESTS; do
    if [[ "$TEST_NAME" == -* ]]; then
      if [[ -n "${SKIP_TESTS:-}" ]]; then
        SKIP_TESTS+=",${TEST_NAME:1}"
      else
        SKIP_TESTS="${TEST_NAME:1}"
      fi
    else
      if [[ -n "${ONLY_TESTS:-}" ]]; then
        ONLY_TESTS+=",$TEST_NAME"
      else
        ONLY_TESTS="$TEST_NAME"
      fi
    fi
  done
  IFS=$OLD_IFS

  if [[ -n "${SKIP_TESTS:-}" ]]; then
    XCTESTRUN_SKIP_TEST_SECTION="\n"
    for SKIP_TEST in ${SKIP_TESTS//,/ }; do
      XCTESTRUN_SKIP_TEST_SECTION+="      <string>$SKIP_TEST</string>\n"
    done
    XCTESTRUN_SKIP_TEST_SECTION="    <key>SkipTestIdentifiers</key>\n    <array>$XCTESTRUN_SKIP_TEST_SECTION    </array>"
  fi

  if [[ -n "${ONLY_TESTS:-}" ]]; then
    XCTESTRUN_ONLY_TEST_SECTION="\n"
    for ONLY_TEST in ${ONLY_TESTS//,/ }; do
      XCTESTRUN_ONLY_TEST_SECTION+="      <string>$ONLY_TEST</string>\n"
    done
    XCTESTRUN_ONLY_TEST_SECTION="    <key>OnlyTestIdentifiers</key>\n    <array>$XCTESTRUN_ONLY_TEST_SECTION    </array>"
  fi
fi

XCTESTRUN="$TEST_TMP_DIR/tests.xctestrun"
cp -f "$BAZEL_XCTESTRUN_TEMPLATE" "$XCTESTRUN"

declare -r sed_delim=$'\001'

/usr/bin/sed \
  -e "s${sed_delim}BAZEL_TEST_PRODUCT_MODULE_NAME${sed_delim}${TEST_BUNDLE_NAME//-/_}${sed_delim}g" \
  -e "s${sed_delim}BAZEL_TEST_BUNDLE_PATH${sed_delim}$XCTESTRUN_TEST_BUNDLE_PATH${sed_delim}g" \
  -e "s${sed_delim}BAZEL_TEST_HOST_BASED${sed_delim}$XCTESTRUN_TEST_HOST_BASED${sed_delim}g" \
  -e "s${sed_delim}BAZEL_TEST_HOST_BINARY${sed_delim}$XCTESTRUN_TEST_HOST_BINARY${sed_delim}g" \
  -e "s${sed_delim}BAZEL_TEST_HOST_BUNDLE_IDENTIFIER${sed_delim}$XCTESTRUN_TEST_HOST_BUNDLE_IDENTIFIER${sed_delim}g" \
  -e "s${sed_delim}BAZEL_TEST_HOST_PATH${sed_delim}$XCTESTRUN_TEST_HOST_PATH${sed_delim}g" \
  -e "s${sed_delim}BAZEL_TARGET_APP_PATH${sed_delim}$XCTESTRUN_TARGET_APP_PATH${sed_delim}g" \
  -e "s${sed_delim}BAZEL_DYLD_FRAMEWORK_PATH${sed_delim}$XCTESTRUN_DYLD_FRAMEWORK_PATH${sed_delim}g" \
  -e "s${sed_delim}BAZEL_DYLD_LIBRARY_PATH${sed_delim}$XCTESTRUN_DYLD_LIBRARY_PATH${sed_delim}g" \
  -e "s${sed_delim}BAZEL_TEST_ENVIRONMENT${sed_delim}$XCTESTRUN_ENV${sed_delim}g" \
  -e "s${sed_delim}BAZEL_SKIP_TEST_SECTION${sed_delim}$XCTESTRUN_SKIP_TEST_SECTION${sed_delim}g" \
  -e "s${sed_delim}BAZEL_ONLY_TEST_SECTION${sed_delim}$XCTESTRUN_ONLY_TEST_SECTION${sed_delim}g" \
  -i "" \
  "$XCTESTRUN"

if [[ -n "${DEBUG_XCTESTRUNNER:-}" ]]; then
  echo "note: instantiated xctestrun:"
  cat "$XCTESTRUN"
fi

if [[ -n "${NO_CLEAN:-}" ]]; then
  DEBUG_SNAPSHOT_DIR="/tmp/clipkitty-macos-ui-runner-last"
  rm -rf "$DEBUG_SNAPSHOT_DIR"
  cp -R "$TEST_TMP_DIR" "$DEBUG_SNAPSHOT_DIR"
  echo "note: copied test dir snapshot to: $DEBUG_SNAPSHOT_DIR"
fi

if [[ "$XML_OUTPUT_FILE" != /* ]]; then
  export XML_OUTPUT_FILE="$PWD/$XML_OUTPUT_FILE"
fi

pre_action_binary=%(pre_action_binary)s
"$pre_action_binary"

readonly result_bundle_path="$TEST_UNDECLARED_OUTPUTS_DIR/tests.xcresult"
rm -rf "$result_bundle_path"

test_exit_code=0
readonly testlog="$TEST_TMP_DIR/test.log"

xcodebuild test-without-building \
  -destination "platform=macOS,variant=macos,arch=$(uname -m)" \
  -resultBundlePath "$result_bundle_path" \
  -xctestrun "$XCTESTRUN" \
  2>&1 | tee -i "$testlog" || test_exit_code=$?

post_action_binary=%(post_action_binary)s
post_action_determines_exit_code="%(post_action_determines_exit_code)s"
post_action_exit_code=0
TEST_EXIT_CODE=$test_exit_code \
  TEST_LOG_FILE="$testlog" \
  TEST_XCRESULT_BUNDLE_PATH="$result_bundle_path" \
  "$post_action_binary" || post_action_exit_code=$?

if [[ "$post_action_determines_exit_code" == true ]]; then
  if [[ "$post_action_exit_code" -ne 0 ]]; then
    echo "error: post_action exited with '$post_action_exit_code'" >&2
    exit "$post_action_exit_code"
  fi
else
  if [[ "$test_exit_code" -ne 0 ]]; then
    echo "error: tests exited with '$test_exit_code'" >&2
    exit "$test_exit_code"
  fi
fi

if [[ "${COVERAGE:-0}" -ne 1 ]]; then
  if [[ -f "${TEST_PREMATURE_EXIT_FILE:-}" ]]; then
    rm -f "$TEST_PREMATURE_EXIT_FILE"
  fi

  exit 0
fi

llvm_coverage_manifest="$COVERAGE_MANIFEST"
readonly provided_coverage_manifest="%(test_coverage_manifest)s"
if [[ -s "${provided_coverage_manifest:-}" ]]; then
  llvm_coverage_manifest="$provided_coverage_manifest"
fi

readonly profdata="$TEST_TMP_DIR/coverage.profdata"
xcrun llvm-profdata merge "$profraw" --output "$profdata"

readonly export_error_file="$TEST_TMP_DIR/llvm-cov-export-error.txt"
llvm_cov_export_status=0
lcov_args=(
  -instr-profile "$profdata"
  -ignore-filename-regex='.*external/.+'
  -path-equivalence=".,$PWD"
)
xcrun llvm-cov \
  export \
  -format lcov \
  "${lcov_args[@]}" \
  "$test_binary" \
  @"$llvm_coverage_manifest" \
  > "$COVERAGE_OUTPUT_FILE" \
  2> "$export_error_file" \
  || llvm_cov_export_status=$?

if [[ -s "$export_error_file" || "$llvm_cov_export_status" -ne 0 ]]; then
  echo "error: while exporting coverage report" >&2
  cat "$export_error_file" >&2
  exit 1
fi

if [[ -n "${COVERAGE_PRODUCE_JSON:-}" ]]; then
  llvm_cov_json_export_status=0
  xcrun llvm-cov \
    export \
    -format text \
    "${lcov_args[@]}" \
    "$test_binary" \
    @"$llvm_coverage_manifest" \
    > "$TEST_UNDECLARED_OUTPUTS_DIR/coverage.json" \
    2> "$export_error_file" \
    || llvm_cov_json_export_status=$?
  if [[ -s "$export_error_file" || "$llvm_cov_json_export_status" -ne 0 ]]; then
    echo "error: while exporting json coverage report" >&2
    cat "$export_error_file" >&2
    exit 1
  fi
fi

if [[ -f "${TEST_PREMATURE_EXIT_FILE:-}" ]]; then
  rm -f "$TEST_PREMATURE_EXIT_FILE"
fi
