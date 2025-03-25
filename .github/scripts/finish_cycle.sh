#!/bin/bash
# finish_cycle.sh - Creates PACKAGES index and preserves old packages
# Usage: ./finish_cycle.sh <run-id> <old-packages-url> <container-image>

if [ $# -ne 3 ]; then
    echo "Error: Invalid arguments"
    echo "Usage: $0 <run-id> <old-packages-url> <container-image>"
    exit 1
fi

RUN_ID=$1
OLD_URL=$2
CONTAINER=$3
NAMESPACE="ns-${RUN_ID}"
PVC_NAME="bioc-pvc-${RUN_ID}"

# First create rclone config secret if not exists
echo "Creating rclone config secret..."
TMPFILE=$(mktemp)
echo "$RCLONE_CONF" > "${TMPFILE}"
kubectl create secret generic rclone-config \
  --from-file=rclone.conf="${TMPFILE}" \
  -n ${NAMESPACE} || true
rm -f "${TMPFILE}"

# Create the indexing job
echo "Creating package indexing job..."
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: index-packages-${RUN_ID}
  namespace: ${NAMESPACE}
spec:
  template:
    spec:
      initContainers:
      - name: package-indexer
        image: ${CONTAINER}
        command: ["/bin/bash", "-c"]
        args:
        - |
          set -euxo pipefail
          mkdir -p /tmp/pkglinks
          cd /mnt/tarballs
          
          # Link new packages
          for tarball in *.tar.gz; do
            [ -f "\$tarball" ] && ln -s "/mnt/tarballs/\$tarball" "/tmp/pkglinks/\$tarball"
            [ -f "\$tarball" ] && echo "\${tarball%%_*}" >> /tmp/new_packages.txt
          done
          
          # Handle old packages if URL provided
          if [ -n "${OLD_URL}" ] && curl -sfL "${OLD_URL}" -o /tmp/old_packages; then
            grep "^Package:" /tmp/old_packages | cut -d' ' -f2 > /tmp/old_packages.txt
            comm -23 <(sort /tmp/old_packages.txt) <(sort /tmp/new_packages.txt) | while read pkg; do
              pkg_pattern="\${pkg}_.*\\.tar\\.gz"
              old_tarball=\$(grep -h "\$pkg_pattern" /tmp/old_packages | grep "^Filename:" | cut -d' ' -f2)
              [ -n "\$old_tarball" ] && curl -sfL "${OLD_URL%/*}/\$old_tarball" -o "/tmp/pkglinks/\$old_tarball"
            done
          fi
          
          # Generate index
          cd /tmp/pkglinks
          Rscript -e 'tools::write_PACKAGES(".", addFiles = TRUE, verbose = TRUE, latestOnly = TRUE)'
          cp PACKAGES* /mnt/tarballs/
        volumeMounts:
        - name: bioc-data
          mountPath: /mnt
      containers:
      - name: rclone-sync
        image: rclone/rclone:latest
        command: ["rclone"]
        args:
        - "copy"
        - "--verbose"
        - "--progress"
        - "/mnt/tarballs/"
        - "final:/bioconductor-packages/$(cat runs/$RUN_ID/bioc_version)/container-binaries/bioconductor_docker/src/contrib/"
        volumeMounts:
        - name: bioc-data
          mountPath: /mnt
        - name: rclone-config
          mountPath: /config/rclone
          readOnly: true
        - name: bioc-version
          mountPath: /bioc-version
          subPath: version
        env:
        - name: RCLONE_CONFIG
          value: /config/rclone/rclone.conf
      volumes:
      - name: bioc-data
        persistentVolumeClaim:
          claimName: ${PVC_NAME}
      - name: rclone-config
        secret:
          secretName: rclone-config
          items:
          - key: rclone.conf
            path: rclone.conf
      - name: bioc-version
        configMap:
          name: bioc-version
      restartPolicy: OnFailure
EOF

echo "Waiting for indexing to complete..."
# Wait for init container to finish
kubectl wait --for=condition=initialized=true pod \
  -l job-name=index-packages-${RUN_ID} \
  -n ${NAMESPACE} --timeout=7200s

# Copy PACKAGES file and save stats
echo "Copying PACKAGES and saving stats..."
POD_NAME=$(kubectl get pod -n ${NAMESPACE} -l job-name=index-packages-${RUN_ID} -o name | cut -d/ -f2)
kubectl cp ${NAMESPACE}/${POD_NAME}:/mnt/tarballs/PACKAGES runs/${RUN_ID}/PACKAGES
PKG_COUNT=$(grep -c '^Package:' "runs/${RUN_ID}/PACKAGES")
echo "${PKG_COUNT}" > "runs/${RUN_ID}/indexed_packages_count"

# Record completion time
TZ=EST date '+%Y-%m-%d %H:%M:%S %Z' > "runs/${RUN_ID}/cycle_complete_time"

# Wait for final sync to complete
echo "Waiting for rclone sync to complete..."
kubectl wait --for=condition=complete job/index-packages-${RUN_ID} \
  -n ${NAMESPACE} --timeout=14400s

echo "Package indexing and sync completed for run: ${RUN_ID} with ${PKG_COUNT} packages"
