#!/bin/bash
# update_runs_table.sh - Updates the runs table in the main README.md

# Check if README.md exists, create if not
if [ ! -f "README.md" ]; then
  echo "# R Binaries Kubernetes Builder" > README.md
  echo "" >> README.md
  echo "<!-- RUNS_TABLE_START -->" >> README.md
  echo "<!-- RUNS_TABLE_END -->" >> README.md
fi

# Make sure the markers exist in the README
if ! grep -q "<!-- RUNS_TABLE_START -->" README.md; then
  # Add markers at the top if they don't exist
  sed -i '1i <!-- RUNS_TABLE_END -->' README.md
  sed -i '1i <!-- RUNS_TABLE_START -->' README.md
fi

# Create runs table
echo "Generating runs table..."
echo "| Run ID | Start Time | Container Image | Status | Success | Failed | Total |" > runs-table.md
echo "|--------|------------|-----------------|--------|---------|--------|-------|" >> runs-table.md

# Process runs directories in reverse chronological order
find runs -maxdepth 1 -mindepth 1 -type d | sort -r | while read -r run_dir; do
  run_id=$(basename "$run_dir")
  
  # Get container image if available
  container_img="N/A"
  if [ -f "${run_dir}/CONTAINER_BASE_IMAGE.bioc" ]; then
    container_img=$(cat "${run_dir}/CONTAINER_BASE_IMAGE.bioc" | awk -F':' '{print $2}' | cut -c 1-15)
  fi
  
  # Get run status
  status="In Progress"
  if [ -f "${run_dir}/cycle_complete_time" ]; then
    status="Complete"
  fi
  
  # Get start time from run_id (formatted)
  start_time=$(echo "$run_id" | sed 's/-/ /g' | awk '{print $1"-"$2"-"$3" "$4":"$5":"$6}')
  
  # Count successful and failed packages
  success_count=$(find "${run_dir}" -type f -name "build-success.log" | wc -l)
  failed_count=$(find "${run_dir}" -type f -name "build-fail.log" | wc -l)
  total_count=$((success_count + failed_count))
  
  # Add row to table
  echo "| [${run_id}](${run_dir}/README.md) | ${start_time} | \`${container_img}\` | ${status} | ${success_count} | ${failed_count} | ${total_count} |" >> runs-table.md
done

# Create temporary file for new README content
TEMP_README=$(mktemp)

# Use grep to extract parts before and after the table markers and combine with the new table
grep -B100000 "<!-- RUNS_TABLE_START -->" README.md > "${TEMP_README}" 2>/dev/null || echo "# R Binaries Kubernetes Builder" > "${TEMP_README}"
echo "" >> "${TEMP_README}"
echo "<!-- RUNS_TABLE_START -->" >> "${TEMP_README}"
cat runs-table.md >> "${TEMP_README}"
echo "" >> "${TEMP_README}"
echo "<!-- RUNS_TABLE_END -->" >> "${TEMP_README}"
grep -A100000 "<!-- RUNS_TABLE_END -->" README.md | tail -n +2 >> "${TEMP_README}" 2>/dev/null

# Replace README with new content
mv "${TEMP_README}" README.md

echo "Runs table updated in README.md"
