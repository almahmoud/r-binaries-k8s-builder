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
SUCCESS_PKGS="runs/${RUN_ID}/logs/successful-packages.txt"
DISPATCHED_PKGS="runs/${RUN_ID}/logs/dispatched-packages.txt"

# Create files if they don't exist
touch "${FAILED_PKGS}" "${SUCCESS_PKGS}" "${DISPATCHED_PKGS}"

# Create temporary files for tracking updates
TEMP_FAILED=$(mktemp)
TEMP_SUCCESS=$(mktemp)
TEMP_DISPATCH=$(mktemp)

# Function to check and mark package status
check_package_status() {
    local pkg="$1"
    local log_dir="runs/${RUN_ID}/logs/${pkg}"
    local status="unknown"
    
    # If package has no log directory, mark as dispatched but no status
    if [ ! -d "${log_dir}" ]; then
        echo "Package ${pkg} has no log directory but was dispatched"
        status="missing"
    # Check for success log
    elif [ -f "${log_dir}/build-success.log" ]; then
        echo "Package ${pkg} has successful build log"
        status="success"
    # Check for fail log
    elif [ -f "${log_dir}/build-fail.log" ]; then
        echo "Package ${pkg} has failed build log"
        status="failed"
    # No status logs found
    else
        echo "Package ${pkg} has log directory but no status logs"
        status="incomplete"
    fi
    
    echo "${status}"
}

# Copy existing files to temporary files
cat "${FAILED_PKGS}" > "${TEMP_FAILED}"
cat "${SUCCESS_PKGS}" > "${TEMP_SUCCESS}"
cat "${DISPATCHED_PKGS}" > "${TEMP_DISPATCH}"

# Process known failed packages first
if [ -s "${FAILED_PKGS}" ]; then
    echo "Processing known failed packages..."
    
    # Make a backup of the failed packages list
    cp "${FAILED_PKGS}" "${FAILED_PKGS}.bak"
    
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
        
        # Add package back to ready packages to be dispatched
        echo "${pkg}" >> "runs/${RUN_ID}/ready_packages.txt"
        
        echo "Reset complete for ${pkg}"
    done < "${FAILED_PKGS}"
fi

echo "Looking for dispatched packages with missing or incomplete status..."

# Process all dispatched packages
while read pkg; do
    if [ -z "${pkg}" ]; then
        continue
    fi
    
    # Skip packages already in success list
    if grep -q "^${pkg}$" "${SUCCESS_PKGS}"; then
        continue
    fi
    
    # Check status for packages that are dispatched but not in the success or failed lists
    if ! grep -q "^${pkg}$" "${FAILED_PKGS}"; then
        status=$(check_package_status "${pkg}")
        
        case "${status}" in
            "success")
                echo "Adding ${pkg} to success list"
                echo "${pkg}" >> "${TEMP_SUCCESS}"
                ;;
            "failed" | "missing" | "incomplete")
                echo "Package ${pkg} needs reset (status: ${status})"
                
                # Remove package log directory if it exists
                if [ -d "runs/${RUN_ID}/logs/${pkg}" ]; then
                    rm -rf "runs/${RUN_ID}/logs/${pkg}"
                fi
                
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
                
                # Add back to ready packages
                echo "${pkg}" >> "runs/${RUN_ID}/ready_packages.txt"
                
                echo "Reset complete for ${pkg} (previously ${status})"
                ;;
            *)
                echo "Unknown status for ${pkg}: ${status}"
                ;;
        esac
    fi
done < "${DISPATCHED_PKGS}"

# Update the files with our processed lists
sort -u "${TEMP_SUCCESS}" > "${SUCCESS_PKGS}"
# Clear failed packages file as we've reset them all
> "${FAILED_PKGS}"

# Clean up temp files
rm -f "${TEMP_FAILED}" "${TEMP_SUCCESS}" "${TEMP_DISPATCH}"

# Force regeneration of dependency graph by updating the remaining-packages.json timestamp
if [ -f "runs/${RUN_ID}/remaining-packages.json" ]; then
    touch "runs/${RUN_ID}/remaining-packages.json"
fi

echo "All failed and stalled packages have been reset"
exit 0
