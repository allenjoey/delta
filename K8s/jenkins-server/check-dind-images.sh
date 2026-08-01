#!/bin/bash

NAMESPACE="jenkins-server"

echo "=== Finding DinD Pod ==="
DIND_POD=$(kubectl get pods -n $NAMESPACE -l io.kompose.service=jenkins-docker -o name | cut -d/ -f2)

if [ -z "$DIND_POD" ]; then
    echo "❌ DinD pod not found! Trying alternate label..."
    DIND_POD=$(kubectl get pods -n $NAMESPACE | grep docker | awk '{print $1}')
fi

if [ -z "$DIND_POD" ]; then
    echo "❌ No DinD pod found in namespace $NAMESPACE"
    exit 1
fi

echo "✓ Found DinD pod: $DIND_POD"

echo -e "\n=== All Docker Images in DinD Storage ==="
kubectl exec -it $DIND_POD -n $NAMESPACE -- docker images

echo -e "\n=== Storage Usage ==="
kubectl exec -it $DIND_POD -n $NAMESPACE -- docker system df

echo -e "\n=== Image Count by Repository ==="
kubectl exec -it $DIND_POD -n $NAMESPACE -- docker images --format "table {{.Repository}}" | tail -n +2 | sort | uniq -c

exit 0