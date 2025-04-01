#!/bin/bash
# archive_runs.sh - Updates READMEs with permanent links and removes logs for old runs
# Usage: ./archive_runs.sh <new-run-id>

set -e

if [ $# -ne 1 ]; then
    echo "Error: Invalid arguments"
    echo "Usage: $0 <new-run-id>"
    exit 1
fi

NEW_RUN_ID=$1
REPO_URL=$(git config --get remote.origin.url | sed 's/\.git$//g' | sed 's/git@github.com:/https:\/\/github.com\//g')
CURRENT_COMMIT=$(git rev-parse HEAD)
REPO_OWNER=$(echo "$REPO_URL" | sed -E 's/.*github.com\/([^\/]+)\/([^\/]+).*/\1/')
REPO_NAME=$(echo "$REPO_URL" | sed -E 's/.*github.com\/([^\/]+)\/([^\/]+).*/\2/')

echo "Archiving old runs before starting new run: $NEW_RUN_ID"
echo "Repository: $REPO_URL"
echo "Current commit: $CURRENT_COMMIT"

# Find all previous runs (excluding the new one we're about to create)
PREV_RUNS=$(find runs -maxdepth 1 -mindepth 1 -type d -name '[0-9]*-*-*-*-*-*' | sort)

if [ -z "$PREV_RUNS" ]; then
    echo "No previous runs found to archive."
    exit 0
fi

echo "Found ${#PREV_RUNS[@]} previous runs to archive."

# Process each previous run
for run_dir in $PREV_RUNS; do
    run_id=$(basename "$run_dir")
    readme_file="${run_dir}/README.md"
    
    echo "Processing run: ${run_id}"
    
    # Skip if no README exists
    if [ ! -f "$readme_file" ]; then
        echo "  No README found, skipping..."
        continue
    fi
    
    # Check if run is already archived
    if grep -q "ARCHIVED RUN" "$readme_file"; then
        echo "  Run already archived, skipping..."
        continue
    fi
    
    echo "  Updating README links to permanent GitHub URLs..."
    
    # Add archive notice at the top
    sed -i "1s/^/> **ARCHIVED RUN:** This run has been archived. Log files have been removed but links below point to the archived version at commit ${CURRENT_COMMIT}.\n\n/" "$readme_file"
    
    # Replace relative log links with absolute GitHub links
    sed -i -E "s|\[Log\]\(logs/([^/]+)/([^)]+)\)|[Log](${REPO_URL}/blob/${CURRENT_COMMIT}/${run_dir}/logs/\1/\2)|g" "$readme_file"
    
    # Clean up logs and cache directories
    if [ -d "${run_dir}/logs" ]; then
        echo "  Removing logs directory..."
        rm -rf "${run_dir}/logs"
    fi
    
    if [ -d "${run_dir}/cache" ]; then
        echo "  Removing cache directory..."
        rm -rf "${run_dir}/cache"
    fi
    
    # Create placeholder to maintain structure
    mkdir -p "${run_dir}/archived"
    echo "This run has been archived. Log files were removed on $(date) when run ${NEW_RUN_ID} was created." > "${run_dir}/archived/README.md"
    
    echo "  Run ${run_id} archived successfully."
done

echo "All previous runs have been archived."
