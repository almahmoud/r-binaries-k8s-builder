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

echo "Resetting failed packages for run: ${RUN_ID}"

while read pkg; do
    echo "Resetting ${pkg}..."
    # Remove log directory
    rm -rf "runs/${RUN_ID}/logs/${pkg}"
    
    # Remove from handled packages cache
    sed -i "\:^${pkg}$:d" "runs/${RUN_ID}/cache/handled_packages.txt" 2>/dev/null
    
    # Remove from failed packages list
    sed -i "\:^${pkg}$:d" "${FAILED_PKGS}"
    
    # Remove from table cache
    sed -i "\:\[${pkg}\]:d" "runs/${RUN_ID}/cache/table_failed.txt" 2>/dev/null
    
    echo "Reset complete for ${pkg}"
done < "${FAILED_PKGS}"

# Clean up empty failed packages file
rm "${FAILED_PKGS}"
touch "${FAILED_PKGS}"

echo "All failed packages have been reset"
