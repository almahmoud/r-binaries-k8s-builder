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

# Reset counters
RESET_COUNT=0
FIXED_COUNT=0

# Get paths to status files
SUCCESS_PKGS="runs/${RUN_ID}/logs/successful-packages.txt"
FAILED_PKGS="runs/${RUN_ID}/logs/failed-packages.txt"
DISPATCHED_PKGS="runs/${RUN_ID}/logs/dispatched-packages.txt"

# Create files if they don't exist
mkdir -p "runs/${RUN_ID}/logs"
touch "${SUCCESS_PKGS}" "${FAILED_PKGS}" "${DISPATCHED_PKGS}"

# Create temporary files for tracking packages
TEMP_SUCCESS=$(mktemp)
TEMP_FAILED=$(mktemp)
TEMP_DISPATCH=$(mktemp)
TEMP_RESET=$(mktemp)

# Backup the original files
cp "${SUCCESS_PKGS}" "${SUCCESS_PKGS}.bak" 2>/dev/null
cp "${FAILED_PKGS}" "${FAILED_PKGS}.bak" 2>/dev/null
cp "${DISPATCHED_PKGS}" "${DISPATCHED_PKGS}.bak" 2>/dev/null

echo "Scanning log directories for package build status..."

# Quickly find packages with build-success.log files
echo "Finding successful builds..."
find "runs/${RUN_ID}/logs" -name "build-success.log" | while read success_log; do
    # Extract package name from path
    pkg=$(echo "${success_log}" | sed -E 's|runs/'${RUN_ID}'/logs/([^/]+)/build-success.log|\1|')
    if [ -n "${pkg}" ]; then
        echo "${pkg}" >> "${TEMP_SUCCESS}"
    fi
done

# Sort and deduplicate
sort -u "${TEMP_SUCCESS}" > "${SUCCESS_PKGS}"
SUCCESS_COUNT=$(wc -l < "${SUCCESS_PKGS}")
echo "Found ${SUCCESS_COUNT} packages with successful builds"

# Find packages with build-fail.log files
echo "Finding failed builds..."
find "runs/${RUN_ID}/logs" -name "build-fail.log" | while read fail_log; do
    # Extract package name from path
    pkg=$(echo "${fail_log}" | sed -E 's|runs/'${RUN_ID}'/logs/([^/]+)/build-fail.log|\1|')
    if [ -n "${pkg}" ]; then
        echo "${pkg}" >> "${TEMP_FAILED}"
    fi
done

# Sort and deduplicate failed packages
sort -u "${TEMP_FAILED}" > "${TEMP_RESET}"
sort -u "${TEMP_FAILED}" > "${FAILED_PKGS}"
FAILED_COUNT=$(wc -l < "${FAILED_PKGS}")
echo "Found ${FAILED_COUNT} packages with failed builds"

# Now find all packages that are dispatched but have no status
echo "Finding dispatched packages without status..."
if [ -s "${DISPATCHED_PKGS}" ]; then
    # Put all dispatched packages into temp file
    sort -u "${DISPATCHED_PKGS}" > "${TEMP_DISPATCH}"
    
    # Find packages that are dispatched but not in success or failed lists
    grep -v -f "${SUCCESS_PKGS}" "${TEMP_DISPATCH}" | grep -v -f "${FAILED_PKGS}" > "${TEMP_DISPATCH}.unknown"
    
    # Check each unknown package
    UNKNOWN_COUNT=$(wc -l < "${TEMP_DISPATCH}.unknown")
    if [ "${UNKNOWN_COUNT}" -gt 0 ]; then
        echo "Found ${UNKNOWN_COUNT} dispatched packages with unknown status"
        
        while read pkg; do
            # First check if the package log directory exists
            if [ -d "runs/${RUN_ID}/logs/${pkg}" ]; then
                echo "Package ${pkg} has log directory but no status"
                # Add to reset list
                echo "${pkg}" >> "${TEMP_RESET}"
            fi
        done < "${TEMP_DISPATCH}.unknown"
    fi
fi

# Process failed and stalled packages for reset
if [ -s "${TEMP_RESET}" ]; then
    RESET_COUNT=$(wc -l < "${TEMP_RESET}")
    echo "Resetting ${RESET_COUNT} failed or stalled packages"
    
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
        
        # Remove from table caches
        if [ -f "runs/${RUN_ID}/cache/table_failed.txt" ]; then
            sed -i "\:\[${pkg}\]:d" "runs/${RUN_ID}/cache/table_failed.txt" 2>/dev/null
        fi
        if [ -f "runs/${RUN_ID}/cache/table_succeeded.txt" ]; then
            sed -i "\:\[${pkg}\]:d" "runs/${RUN_ID}/cache/table_succeeded.txt" 2>/dev/null
        fi
        
        # Remove from verified BBS cache
        if [ -f "runs/${RUN_ID}/cache/verified_bbs.txt" ]; then
            sed -i "\:^${pkg}$:d" "runs/${RUN_ID}/cache/verified_bbs.txt" 2>/dev/null
        fi
        
        # Add back to ready packages for dispatch
        echo "${pkg}" >> "runs/${RUN_ID}/ready_packages.txt"
        
        echo "Reset complete for ${pkg}"
    done < "${TEMP_RESET}"
    
    # Clear failed packages file as they've been reset
    > "${FAILED_PKGS}"
fi

# Check for differences between original and new status files
if [ -f "${SUCCESS_PKGS}.bak" ]; then
    DIFF_SUCCESS=$(diff "${SUCCESS_PKGS}.bak" "${SUCCESS_PKGS}" | wc -l)
    if [ "${DIFF_SUCCESS}" -gt 0 ]; then
        FIXED_COUNT=$((FIXED_COUNT + DIFF_SUCCESS))
    fi
fi

if [ -f "${FAILED_PKGS}.bak" ]; then
    DIFF_FAILED=$(diff "${FAILED_PKGS}.bak" "${FAILED_PKGS}" | wc -l)
    if [ "${DIFF_FAILED}" -gt 0 ]; then
        FIXED_COUNT=$((FIXED_COUNT + DIFF_FAILED))
    fi
fi

# Clean up temporary files
rm -f "${TEMP_SUCCESS}" "${TEMP_FAILED}" "${TEMP_DISPATCH}" "${TEMP_RESET}" "${TEMP_DISPATCH}.unknown"

# Force regeneration of dependency graph by updating the remaining-packages.json timestamp
if [ -f "runs/${RUN_ID}/remaining-packages.json" ]; then
    touch "runs/${RUN_ID}/remaining-packages.json"
fi

echo "Reset completed:"
echo "- ${RESET_COUNT} packages reset for retry"
echo "- ${FIXED_COUNT} inconsistent status entries fixed"
echo "- ${SUCCESS_COUNT} valid successful package entries"

exit 0
