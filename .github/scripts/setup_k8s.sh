#!/bin/bash
# setup_k8s.sh - Creates PVC and Busybox pod for Bioconductor builds
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
BUSYBOX_POD="busybox-$(sanitize_name ${RUN_ID})"

# Create namespace
echo "Creating namespace: ${NAMESPACE}"
kubectl create namespace ${NAMESPACE}

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

# Create Busybox pod with PVC mount
echo "Creating Busybox pod: ${BUSYBOX_POD}"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${BUSYBOX_POD}
  namespace: ${NAMESPACE}
  labels:
    app: bioc-monitor
    run-id: ${RUN_ID}
spec:
  containers:
  - name: busybox
    image: busybox:latest
    command: ["/bin/sh", "-c", "tail -f /dev/null"]
    volumeMounts:
    - name: bioc-data
      mountPath: /mnt
  volumes:
  - name: bioc-data
    persistentVolumeClaim:
      claimName: ${PVC_NAME}
EOF

# Wait for pod to be ready
echo "Waiting for pod to be ready..."
kubectl wait --for=condition=Ready pod/${BUSYBOX_POD} -n ${NAMESPACE} --timeout=120s

echo "Setup completed for run: ${RUN_ID}"
echo "PVC Name: ${PVC_NAME}"
echo "Busybox Pod Name: ${BUSYBOX_POD}"
