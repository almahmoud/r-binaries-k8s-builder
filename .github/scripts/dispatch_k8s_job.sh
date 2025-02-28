#!/bin/bash
# dispatch_k8s_job.sh - Creates and deploys a Kubernetes Job for R package installation
# Usage: ./dispatch_k8s_job.sh <package-name> <container-image> <pvc-name> <run-id>

# Validate input parameters
if [ $# -ne 4 ]; then
    echo "Error: Invalid arguments"
    echo "Usage: $0 <package-name> <container-image> <pvc-name> <run-id>"
    exit 1
fi

# Sanitize names for DNS compliance
sanitize_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-.'
}

PKG_SAFE=$(sanitize_name "$1")
PKG=$1
CONTAINER=$2
PVC=$3
RUN_ID=$(sanitize_name "$4")
NAMESPACE="ns-${RUN_ID}"

# Record dispatched package
mkdir -p "runs/${RUN_ID}/logs"
echo "$PKG" >> "runs/${RUN_ID}/logs/dispatched-packages.txt"

# Create Kubernetes Job manifest using heredoc
cat << EOF | kubectl apply -n ${NAMESPACE} -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: bioc-build-${PKG_SAFE}-${RUN_ID}
  namespace: ${NAMESPACE}
  labels:
    app: bioc-builder
    pkg: ${PKG}
    run-id: ${RUN_ID}
spec:
  backoffLimit: 5
  template:
    spec:
      containers:
      - name: bioc-builder
        image: ${CONTAINER}
        resources:
          requests:
            cpu: "1"
            memory: "4Gi"
        command: ["/bin/bash", "-c"]
        args:
        - |
          export LIBRARY="/mnt/library"
          export TARDIR="/mnt/tarballs"
          export LOGDIR="/mnt/logs"
          mkdir -p \${TARDIR} \${LOGDIR} \${LIBRARY}
          (time Rscript -e "Sys.setenv(BIOCONDUCTOR_USE_CONTAINER_REPOSITORY=FALSE);
            p <- .libPaths();
            p <- c('\${LIBRARY}', p);
            .libPaths(p);
            if(BiocManager::install('${PKG}', 
                INSTALL_opts = '--build',
                update = TRUE,
                quiet = FALSE,
                dependencies=TRUE,
                force = TRUE,
                keep_outputs = TRUE) %in% rownames(installed.packages())) 
              q(status = 0) 
            else 
              q(status = 1)" 2>&1 ) 2>&1 | tee \${LOGDIR}/${PKG}.log
          echo "Tarballs Detected: \$(ls *.tar.gz)"
          mv *.tar.gz \${TARDIR}/
          echo "Build artifacts stored in \${TARDIR}"
        volumeMounts:
        - name: bioc-data
          mountPath: /mnt
      restartPolicy: OnFailure
      volumes:
      - name: bioc-data
        persistentVolumeClaim:
          claimName: ${PVC}
EOF

echo "Dispatched job for package: ${PKG} with run-id: ${RUN_ID}"
