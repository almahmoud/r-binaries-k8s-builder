#!/bin/bash
# setup_k8s.sh - Creates PVC and Bioconductor pod for Bioconductor builds
# Usage: ./setup_k8s.sh <storage-class> <size> <run-id>

# Validate input parameters
if [ $# -ne 3 ]; then
    echo "Error: Invalid arguments"
    echo "Usage: $0 <storage-class> <size> <run-id>"
    exit 1
fi

# Sanitize names for DNS compliance
sanitize_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-.'
}

STORAGE_CLASS=$1
SIZE=$2
RUN_ID=$3
NAMESPACE="ns-$(sanitize_name ${RUN_ID})"
PVC_NAME="bioc-pvc-$(sanitize_name ${RUN_ID})"
BIOC_POD="bioc-$(sanitize_name ${RUN_ID})"

# Create namespace
echo "Creating namespace: ${NAMESPACE}"
kubectl create namespace ${NAMESPACE}

# Create configmap for R script
echo "Creating deps_json.R configmap..."
kubectl create configmap deps-json-script \
  --from-file=".github/scripts/deps_json.R" \
  -n ${NAMESPACE}

# Create PVC with run-id
echo "Creating PVC: ${PVC_NAME}"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NAMESPACE}
  labels:
    purpose: bioc-build
    run-id: ${RUN_ID}
spec:
  accessModes:
  - ReadWriteMany
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: ${SIZE}
EOF

# Get the container image
CONTAINER_IMAGE=$(cat "runs/${RUN_ID}/CONTAINER_BASE_IMAGE.bioc")
echo "Using container image: ${CONTAINER_IMAGE}"

# Create Bioconductor pod with PVC mount and init container
echo "Creating Bioconductor pod: ${BIOC_POD}"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${BIOC_POD}
  namespace: ${NAMESPACE}
  labels:
    app: bioc-builder
    run-id: ${RUN_ID}
spec:
  initContainers:
  - name: deps-generator
    image: ${CONTAINER_IMAGE}
    command: ["Rscript", "/scripts/deps_json.R", "--biocdeps=/mnt/biocdeps.json", "--uniquedeps=/mnt/uniquedeps.json"]
    volumeMounts:
    - name: bioc-data
      mountPath: /mnt
    - name: deps-script
      mountPath: /scripts
  containers:
  - name: bioc-main
    image: ${CONTAINER_IMAGE}
    command: ["/bin/sh", "-c", "tail -f /dev/null"]
    volumeMounts:
    - name: bioc-data
      mountPath: /mnt
  volumes:
  - name: bioc-data
    persistentVolumeClaim:
      claimName: ${PVC_NAME}
  - name: deps-script
    configMap:
      name: deps-json-script
EOF

# Wait for pod to be ready
echo "Waiting for pod to be ready..."
kubectl wait --for=condition=Ready pod/${BIOC_POD} -n ${NAMESPACE} --timeout=240s

# Copy the generated files from the pod
echo "Copying generated files from pod..."
kubectl cp ${NAMESPACE}/${BIOC_POD}:/mnt/biocdeps.json runs/${RUN_ID}/biocdeps.json
kubectl cp ${NAMESPACE}/${BIOC_POD}:/mnt/uniquedeps.json runs/${RUN_ID}/uniquedeps.json
kubectl cp ${NAMESPACE}/${BIOC_POD}:/mnt/bioc_version runs/${RUN_ID}/bioc_version 2>/dev/null || echo "Warning: bioc_version file not found"
kubectl cp ${NAMESPACE}/${BIOC_POD}:/mnt/r_version runs/${RUN_ID}/r_version 2>/dev/null || echo "Warning: r_version file not found"


# Create configmap for Bioconductor version
echo "Creating Bioconductor version configmap..."
BIOC_VERSION=$(cat "runs/${RUN_ID}/bioc_version" 2>/dev/null || echo "")

if [[ -n "${BIOC_VERSION}" ]]; then
  kubectl create configmap bioc-version \
    --from-literal=version=${BIOC_VERSION} \
    -n ${NAMESPACE}
fi

echo "Setup completed for run: ${RUN_ID}"
echo "PVC Name: ${PVC_NAME}"
echo "Bioc Pod Name: ${BIOC_POD}"
