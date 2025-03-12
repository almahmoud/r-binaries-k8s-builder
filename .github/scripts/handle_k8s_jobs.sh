#!/bin/bash
# handle_k8s_jobs.sh - handles and processes completed Bioconductor build jobs
# Usage: ./handle_k8s_jobs.sh <run-id> <success_packages.txt> <failed_packages.txt>

# Validate input parameters
if [ $# -ne 3 ]; then
    echo "Error: Invalid arguments"
    echo "Usage: $0 <run-id> <success-packages-file> <failed-packages-file>"
    exit 1
fi

# Sanitize names for DNS compliance
sanitize_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-.'
}

RUN_ID=$(sanitize_name "$1")
SUCCESS_PKGS=$2
FAILED_PKGS=$3
BUSYBOX_POD="busybox-${RUN_ID}"
NAMESPACE="ns-${RUN_ID}"

# Create directory structure
mkdir -p "runs/${RUN_ID}/logs"

# Get all jobs in namespace with app=bioc-builder label
JOBS=$(kubectl get jobs -n ${NAMESPACE} -l app=bioc-builder -o custom-columns=NAME:.metadata.name,PKG:.metadata.labels.pkg --no-headers)

# Check and initialize retry counter
RETRY_COUNT_FILE="runs/${RUN_ID}/retry_count"
if [ ! -f "${RETRY_COUNT_FILE}" ]; then
    echo "0" > "${RETRY_COUNT_FILE}"
fi
RETRY_COUNT=$(cat "${RETRY_COUNT_FILE}")

# Function to check for stalled progress and handle retries
check_and_retry() {
    local prev_success_count=0
    local curr_success_count=0
    local retry_needed=0
    
    # Check if we've made progress
    if [ -f "${SUCCESS_PKGS}" ]; then
        prev_success_count=$(cat "${SUCCESS_PKGS}.prev" 2>/dev/null | wc -l || echo "0")
        curr_success_count=$(wc -l < "${SUCCESS_PKGS}" || echo "0")
        cp "${SUCCESS_PKGS}" "${SUCCESS_PKGS}.prev"
    fi
    
    # If no new successes and under retry limit, try again
    if [ "${prev_success_count}" -eq "${curr_success_count}" ] && [ "${RETRY_COUNT}" -lt 5 ]; then
        echo "No progress detected, attempting retry ${RETRY_COUNT}/5..."
        echo "$((RETRY_COUNT + 1))" > "${RETRY_COUNT_FILE}"
        
        # Reset and redispatch failed packages
        bash .github/scripts/reset_failed.sh "${RUN_ID}"
        
        # Find and dispatch new packages
        python .github/scripts/find_ready_pkgs.py \
            "runs/${RUN_ID}/biocdeps.json" \
            "runs/${RUN_ID}/ready_packages.txt" \
            "runs/${RUN_ID}/logs/dispatched-packages.txt" \
            "runs/${RUN_ID}/logs/successful-packages.txt" \
            "runs/${RUN_ID}/remaining-packages.json"
            
        if [ -s "runs/${RUN_ID}/ready_packages.txt" ]; then
            CONTAINER=$(cat "runs/${RUN_ID}/CONTAINER_BASE_IMAGE.bioc")
            cat "runs/${RUN_ID}/ready_packages.txt" | \
                xargs -i bash -c "bash .github/scripts/dispatch_k8s_job.sh {} ${CONTAINER} bioc-pvc-${RUN_ID} ${RUN_ID} && sleep 1"
            return 1  # Continue processing
        fi
    fi
    return 0  # No more retries needed
}

# Process jobs with retry logic
while true; do
    # Process current batch of jobs
    echo "${JOBS}" | while read -r JOB_NAME PKG; do
        if [ -z "${JOB_NAME}" ]; then
            continue
        fi
        
        echo "Processing job: ${JOB_NAME} (Package: ${PKG})..."

        # Get job status
        SUCCEEDED=$(kubectl get job "${JOB_NAME}" -n ${NAMESPACE} \
                    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}')
        FAILED=$(kubectl get job "${JOB_NAME}" -n ${NAMESPACE} \
                 -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}')

        # Skip if job is still running
        if [ "$SUCCEEDED" != "True" ] && [ "$FAILED" != "True" ]; then
            echo "  Job still in progress, skipping..."
            continue
        fi

        # Create package log directory
        LOG_DIR="runs/${RUN_ID}/logs/${PKG}"
        mkdir -p "${LOG_DIR}"
        TMP_LOG="${LOG_DIR}/temp.log"

        # Copy logs from PVC via busybox pod
        echo "  Copying logs from cluster..."
        if ! kubectl cp "${BUSYBOX_POD}:/mnt/logs/${PKG}.log" "${TMP_LOG}" -n ${NAMESPACE} >/dev/null 2>&1; then
            echo "  Log file not found, marking as failed..."
            echo "Build failed: Log file missing" > "${LOG_DIR}/build-fail.log"
            rm -f "${TMP_LOG}"
            echo "$PKG" >> "${FAILED_PKGS}"
        else
            # Check for both download and successful packaging
            TARBALL_EXISTS=0
            if grep -qE "/${PKG}_[^[:space:]]+\.tar\.gz" "${TMP_LOG}" && \
               grep -q "packaged installation of.*${PKG}_.*\.tar\.gz" "${TMP_LOG}"; then
                TARBALL_EXISTS=1
                echo "  Verified package download and successful packaging"
            fi

            # Determine final status
            if [ "$SUCCEEDED" = "True" ] && [ $TARBALL_EXISTS -eq 1 ]; then
                mv "${TMP_LOG}" "${LOG_DIR}/build-success.log"
                echo "  Build succeeded with verified packaging"
                echo "$PKG" >> "${SUCCESS_PKGS}"
            else
                mv "${TMP_LOG}" "${LOG_DIR}/build-fail.log"
                echo "  Build failed or package verification failed"
                echo "$PKG" >> "${FAILED_PKGS}"
            fi
        fi

        # Clean up completed job
        echo "  Deleting completed job..."
        kubectl delete job "${JOB_NAME}" -n ${NAMESPACE} --wait=false >/dev/null 2>&1

    done
    
    # Check if we should retry
    if check_and_retry; then
        break
    fi
    
    # Get fresh list of jobs after retry
    JOBS=$(kubectl get jobs -n ${NAMESPACE} -l app=bioc-builder -o custom-columns=NAME:.metadata.name,PKG:.metadata.labels.pkg --no-headers)
    
    # Break if no jobs left
    if [ -z "${JOBS}" ]; then
        break
    fi
done

echo "Handled complete for run: ${RUN_ID} after $(cat ${RETRY_COUNT_FILE}) retries"
