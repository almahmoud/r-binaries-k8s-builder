#!/bin/bash
# reset_failed.sh - Reset failed packages for retry
# Usage: ./reset_failed.sh <run-id>

if [ $# -ne 1 ]; then
    echo "Error: Invalid arguments"
    echo "Usage: $0 <run-id>"
    exit 1
fi

RUN_ID=$1

# Check run exists
if [ ! -d "runs/${RUN_ID}" ]; then
    echo "Error: Run ${RUN_ID} not found"
    exit 1
fi

# Get list of failed packages
FAILED_PKGS="runs/${RUN_ID}/logs/failed-packages.txt"
if [ ! -f "${FAILED_PKGS}" ]; then
    echo "No failed packages found"
    exit 0
fi

# Check if there are any actual failed packages
FAILED_COUNT=$(wc -l < "${FAILED_PKGS}" || echo "0")
if [ "${FAILED_COUNT}" -eq 0 ]; then
    echo "No failed packages to reset"
    exit 0
fi

echo "Resetting ${FAILED_COUNT} failed packages for run: ${RUN_ID}"

# Make a backup of the failed packages list for verification
cp "${FAILED_PKGS}" "${FAILED_PKGS}.bak"

# Save the failed packages to a temporary file
TEMP_LIST=$(mktemp)
cat "${FAILED_PKGS}" > "${TEMP_LIST}"

# Process each failed package
while read pkg; do
    if [ -z "${pkg}" ]; then
        continue
    fi
    
    echo "Resetting ${pkg}..."
    
    # Remove package log directory
    rm -rf "runs/${RUN_ID}/logs/${pkg}"
    
    # Remove from handled packages cache
    if [ -f "runs/${RUN_ID}/cache/handled_packages.txt" ]; then
        sed -i "\:^${pkg}$:d" "runs/${RUN_ID}/cache/handled_packages.txt" 2>/dev/null
    fi
    
    # Remove from table cache
    if [ -f "runs/${RUN_ID}/cache/table_failed.txt" ]; then
        sed -i "\:\[${pkg}\]:d" "runs/${RUN_ID}/cache/table_failed.txt" 2>/dev/null
    fi
    
    # Remove from verified BBS cache
    if [ -f "runs/${RUN_ID}/cache/verified_bbs.txt" ]; then
        sed -i "\:^${pkg}$:d" "runs/${RUN_ID}/cache/verified_bbs.txt" 2>/dev/null
    fi
    
    # Check if already in dispatched packages
    DISPATCHED_FILE="runs/${RUN_ID}/logs/dispatched-packages.txt"
    if [ -f "${DISPATCHED_FILE}" ] && ! grep -q "^${pkg}$" "${DISPATCHED_FILE}"; then
        echo "Adding ${pkg} back to ready packages to be dispatched"
        echo "${pkg}" >> "runs/${RUN_ID}/ready_packages.txt"
    fi
    
    echo "Reset complete for ${pkg}"
done < "${TEMP_LIST}"

# Clean up the failed packages file
rm "${FAILED_PKGS}"
touch "${FAILED_PKGS}"

# Remove temporary file
rm "${TEMP_LIST}"

# Force regeneration of dependency graph by updating the remaining-packages.json timestamp
if [ -f "runs/${RUN_ID}/remaining-packages.json" ]; then
    touch "runs/${RUN_ID}/remaining-packages.json"
fi

echo "All failed packages have been reset"
exit 0
