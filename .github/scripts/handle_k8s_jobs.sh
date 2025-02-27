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

# Process each job
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
        # Check for tarball existence in logs
        TARBALL_EXISTS=0
        if grep -qE "${PKG}_[^[:space:]]+\.tar\.gz" "${TMP_LOG}"; then
            TARBALL_EXISTS=1
            echo "  Tarball detected in build logs"
        fi

        # Determine final status
        if [ "$SUCCEEDED" = "True" ] && [ $TARBALL_EXISTS -eq 1 ]; then
            mv "${TMP_LOG}" "${LOG_DIR}/build-success.log"
            echo "  Build succeeded with valid tarball"
            echo "$PKG" >> "${SUCCESS_PKGS}"
        else
            mv "${TMP_LOG}" "${LOG_DIR}/build-fail.log"
            echo "  Build failed or missing tarball"
            echo "$PKG" >> "${FAILED_PKGS}"
        fi
    fi

    # Clean up completed job
    echo "  Deleting completed job..."
    kubectl delete job "${JOB_NAME}" -n ${NAMESPACE} --wait=false >/dev/null 2>&1

done

echo "Handled complete for run: ${RUN_ID}"
