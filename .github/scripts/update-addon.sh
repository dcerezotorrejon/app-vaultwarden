#!/usr/bin/env bash
# Bring the add-on version in line with Renovate updates.
# - Vaultwarden or Hassio base image updates -> Major version bump (e.g. 1.0.1 -> 2.0.0) and specific changelog.
# - Other dependency updates -> Minor version bump (e.g. 1.0.1 -> 1.1.0) and specific changelog.
#
# Usage: .github/scripts/update-addon.sh [vaultwarden-version]
set -euo pipefail

root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
dockerfile="${root}/vaultwarden/Dockerfile"
build_yaml="${root}/vaultwarden/build.yaml"
config="${root}/vaultwarden/config.yaml"
changelog="${root}/vaultwarden/CHANGELOG.md"
readme="${root}/README.md"

emit() {
    [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
    printf '%s\n' "$@" >>"${GITHUB_OUTPUT}"
}

cur_addon="$(sed -n 's|^version: \(.*\)$|\1|p' "${config}")"
if [[ -z "${cur_addon}" ]]; then
    echo "Could not read current add-on version from config.yaml" >&2
    exit 1
fi

IFS=. read -r addon_major addon_minor addon_patch <<<"${cur_addon}"

# Determine what changed
changelog_entry=""
bump_type="minor" # default
target=""

# 1. Check if argument passed (explicit Vaultwarden version)
if [[ $# -gt 0 ]]; then
    target="${1#v}"
    pinned="$(sed -n 's|^FROM "vaultwarden/server:\(.*\)" AS vaultwarden$|\1|p' "${dockerfile}")"
    if [[ "${target}" != "${pinned}" ]]; then
        sed -i \
            "s|^FROM \"vaultwarden/server:.*\" AS vaultwarden$|FROM \"vaultwarden/server:${target}\" AS vaultwarden|" \
            "${dockerfile}"
    fi
    bump_type="major"
    changelog_entry="- ⬆️ Update Vaultwarden to ${target}"
elif git diff --unified=0 "${dockerfile}" | grep -q '^+FROM "vaultwarden/server:'; then
    target="$(git diff --unified=0 "${dockerfile}" | sed -n 's|^+FROM "vaultwarden/server:\([^"]*\)".*$|\1|p')"
    bump_type="major"
    changelog_entry="- ⬆️ Update Vaultwarden to ${target}"
elif git diff --unified=0 "${dockerfile}" "${build_yaml}" | grep -qE '\bghcr\.io/hassio-addons/base'; then
    # Base image update
    base_version="$(git diff --unified=0 "${dockerfile}" "${build_yaml}" | grep -oE 'ghcr\.io/hassio-addons/base:[^[:space:]]+' | head -n1 | cut -d: -f2)"
    target="${base_version:-unknown}"
    bump_type="major"
    changelog_entry="- ⬆️ Update base image to ${target}"
else
    # General / other dependency changes
    # Try to extract updated dependency name from git diff or status
    changed_file="$(git diff --name-only HEAD || true)"
    changelog_entry="- ⬆️ Update dependencies"
    bump_type="minor"
    target="dependency"
fi

# Calculate new version based on bump_type
if [[ "${bump_type}" == "major" ]]; then
    new_addon="$((addon_major + 1)).0.0"
else
    new_addon="${addon_major}.$((addon_minor + 1)).0"
fi

sed -i "s|^version: .*$|version: ${new_addon}|" "${config}"

# Prepend the entry to CHANGELOG.md
tmp="$(mktemp)"
{
    printf '# Changelog\n\n## %s\n\n%s\n' \
        "${new_addon}" "${changelog_entry}"
    tail -n +2 "${changelog}"
} >"${tmp}"
mv "${tmp}" "${changelog}"

# Update README if Vaultwarden target is known
if [[ -n "${target}" && "${target}" != "dependency" && "${target}" != "unknown" ]]; then
    before="$(cat "${readme}")"
    sed -i \
        -e "s|^\(# Vaultwarden add-on for Home Assistant — \)[0-9][0-9.]*\( fork\)$|\1${target}\2|" \
        -e "s|\*\*Vaultwarden [0-9][0-9.]*\*\*|**Vaultwarden ${target}**|g" \
        -e "s|\(\`vaultwarden/server\` [0-9][0-9.]* → \*\*\)[0-9][0-9.]*\(\*\*\)|\1${target}\2|" \
        -e "s|a release with [0-9][0-9.]* or newer|a release with ${target} or newer|" \
        "${readme}"
fi

echo "Add-on version bumped (${cur_addon} -> ${new_addon}, bump type: ${bump_type})"
emit "changed=true" "version=${target}" "addon_version=${new_addon}" "bump_type=${bump_type}"
