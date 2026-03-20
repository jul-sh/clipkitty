#!/bin/bash

all_codesigning_identities_available() {
    local identity_name

    for identity_name in "$@"; do
        if ! security find-identity -v -p codesigning 2>/dev/null | grep -F -q "$identity_name"; then
            return 1
        fi
    done
}

delete_temp_keychain() {
    security delete-keychain "$1" 2>/dev/null || true
}

create_unlocked_temp_keychain() {
    local keychain_path=$1
    local keychain_password=$2
    local timeout_seconds=${3:-3600}

    delete_temp_keychain "$keychain_path"
    security create-keychain -p "$keychain_password" "$keychain_path"
    security set-keychain-settings -t "$timeout_seconds" "$keychain_path"
    security unlock-keychain -p "$keychain_password" "$keychain_path"
}

prepend_keychain_to_search_list() {
    local keychain_path=$1
    local existing

    existing=$(security list-keychains -d user | tr -d '" ' | tr '\n' ' ')
    security list-keychains -d user -s "$keychain_path" $existing
}
