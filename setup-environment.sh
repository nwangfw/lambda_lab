#!/bin/bash

# setup_aibrix_benchmark.sh
# Based on https://aibrix.readthedocs.io/latest/getting_started/installation/lambda.html

set -e  # Exit immediately if a command exits with a non-zero status

# Colors for better readability
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Log function
log() {
  echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
  echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" >&2
  exit 1
}

warning() {
  echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   warning "This script may need sudo privileges for some operations."
   warning "You might be prompted for your password during execution."
fi

# Check OS
OS=$(uname -s)
if [[ "$OS" != "Linux" && "$OS" != "Darwin" ]]; then
  error "This script supports only Linux and macOS. Detected OS: $OS"
fi

# Configuration variables
AIBRIX_VERSION="v0.2.1"
#MODEL_NAME="deepseek-r1-distill-llama-8b"
MODEL_NAME="llama-2-7b-hf"
BENCHMARK_OUTPUT_DIR="${SCRIPT_DIR}"
API_KEY="replace with your key"  # Using the API key from the deployment file
HF_TOKEN="replace with your key"   # HuggingFace token for accessing the model
USE_ALT_PORTS=false  # Flag to determine if we need to use alternative ports

# Script directory and AIBrix repository path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIBRIX_REPO_PATH="${SCRIPT_DIR}/aibrix"

#######################################
# Check system requirements
#######################################
check_system_requirements() {
  log "Checking system requirements..."
  
  # Check if Docker is installed and running
  if ! command -v docker &> /dev/null; then
    error "Docker is not installed. Please install Docker and try again."
  fi
  
  if ! docker info &>/dev/null; then
    error "Docker is not running. Please start Docker and try again."
  fi
  
  # Check Docker memory allocation
  DOCKER_MEM=$(docker info | grep "Total Memory" | awk '{print $3}')
  if [[ -n "$DOCKER_MEM" && "${DOCKER_MEM%.*}" -lt 8 ]]; then
    warning "Docker has less than 8GB of memory allocated. This might cause issues."
    warning "Please increase Docker memory allocation to at least 8GB in Docker Desktop settings."
  fi
  
  # Check Docker CPU allocation
  DOCKER_CPUS=$(docker info | grep "CPUs" | awk '{print $2}')
  if [[ -n "$DOCKER_CPUS" && "$DOCKER_CPUS" -lt 4 ]]; then
    warning "Docker has less than 4 CPUs allocated. This might cause performance issues."
    warning "Please increase Docker CPU allocation to at least 4 in Docker Desktop settings."
  fi
  
  # Check if nvidia-smi is available
  if ! command -v nvidia-smi &> /dev/null; then
    warning "nvidia-smi is not available. This might indicate NVIDIA drivers are not installed."
    warning "GPU support may be limited or unavailable."
  else
    # Check if GPUs are available
    GPU_COUNT=$(nvidia-smi --list-gpus | wc -l)
    if [ "$GPU_COUNT" -eq 0 ]; then
      warning "No GPUs detected by nvidia-smi. GPU support may be limited or unavailable."
    else
      log "Detected $GPU_COUNT GPU(s)."
    fi
  fi
  
  # Check if nvkind is installed
  if ! command -v nvkind &> /dev/null; then
    warning "nvkind is not installed. It will be installed during the setup process."
  fi
  
  # Check if kubectl is installed
  if ! command -v kubectl &> /dev/null; then
    warning "kubectl is not installed. It will be installed during the setup process."
  fi
  
  # Check available disk space
  AVAILABLE_SPACE=$(df -h . | awk 'NR==2 {print $4}')
  log "Available disk space: $AVAILABLE_SPACE"
  
  # Extract numeric value and unit
  SPACE_VALUE=$(echo $AVAILABLE_SPACE | sed 's/[^0-9.]//g')
  SPACE_UNIT=$(echo $AVAILABLE_SPACE | sed 's/[0-9.]//g')
  
  # Convert to GB for comparison
  if [[ "$SPACE_UNIT" == "T" || "$SPACE_UNIT" == "Ti" ]]; then
    # Terabytes - multiply by 1000
    SPACE_GB=$(echo "$SPACE_VALUE * 1000" | bc)
  elif [[ "$SPACE_UNIT" == "G" || "$SPACE_UNIT" == "Gi" ]]; then
    # Already in GB
    SPACE_GB=$SPACE_VALUE
  elif [[ "$SPACE_UNIT" == "M" || "$SPACE_UNIT" == "Mi" ]]; then
    # Megabytes - divide by 1000
    SPACE_GB=$(echo "$SPACE_VALUE / 1000" | bc)
  fi
  
  if (( $(echo "$SPACE_GB < 20" | bc -l) )); then
    warning "Less than 20GB of disk space available. This might not be enough for AIBrix and models."
  fi
  
  log "System requirements check completed."
}

#######################################
# 1. Install Dependencies
#######################################
install_dependencies() {
  log "Installing dependencies..."
  
  # Clone AIBrix repository if not already present
  if [ ! -d "${AIBRIX_REPO_PATH}" ]; then
    log "Cloning AIBrix repository..."
    git clone https://github.com/vllm-project/aibrix.git "${AIBRIX_REPO_PATH}"
  else
    log "AIBrix repository already exists, updating..."
    cd "${AIBRIX_REPO_PATH}"
    git pull
    cd "${SCRIPT_DIR}"
  fi
  
  # Run the installation script from AIBrix
  log "Running AIBrix installation script..."
  cd "${AIBRIX_REPO_PATH}"
  bash hack/lambda-cloud/install.sh
  
  # Source bashrc to update environment variables
  source ~/.bashrc
  
  # Check if nvkind is installed
  if ! command -v nvkind &> /dev/null; then
    log "nvkind not found after AIBrix installation. Installing manually..."
    
    # Create local bin directory if it doesn't exist
    mkdir -p ~/.local/bin
    
    # Ensure ~/.local/bin is in PATH
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
      log "Adding ~/.local/bin to PATH..."
      echo 'export PATH=$HOME/.local/bin:$PATH' >> ~/.bashrc
      export PATH="$HOME/.local/bin:$PATH"
    fi
    
    # Download nvkind binary
    log "Downloading nvkind binary..."
    curl -L -o ~/nvkind-linux-amd64.tar.gz https://github.com/Jeffwan/kind-with-gpus-examples/releases/download/v0.1.0/nvkind-linux-amd64.tar.gz
    
    if [ $? -ne 0 ]; then
      error "Failed to download nvkind binary."
    fi
    
    # Extract nvkind binary
    log "Extracting nvkind binary..."
    tar -xzvf ~/nvkind-linux-amd64.tar.gz -C ~/.local/bin/ || error "Failed to extract nvkind binary."
    
    # Make nvkind executable and move to the correct name
    log "Setting up nvkind..."
    chmod +x ~/.local/bin/nvkind-linux-amd64 || error "Failed to make nvkind executable."
    mv ~/.local/bin/nvkind-linux-amd64 ~/.local/bin/nvkind || error "Failed to rename nvkind binary."
    
    # Verify nvkind is installed
    if ! command -v nvkind &> /dev/null; then
      error "nvkind installation failed. Please check the logs."
    else
      log "nvkind installed successfully."
    fi
  else
    log "nvkind is already installed."
  fi
  
  # Verify nvkind version
  log "Checking nvkind version..."
  nvkind --version || warning "Failed to check nvkind version, but continuing anyway."
  
  # Return to script directory
  cd "${SCRIPT_DIR}"
  
  log "Dependencies installed successfully."
}

#######################################
# 2. Verify Installation
#######################################
verify_installation() {
  log "Verifying installation..."
  
  # Run the verification script from AIBrix
  if [ ! -d "${AIBRIX_REPO_PATH}" ]; then
    error "AIBrix repository not found at ${AIBRIX_REPO_PATH}. Please run the install_dependencies step first."
  fi
  
  cd "${AIBRIX_REPO_PATH}"
  bash ./hack/lambda-cloud/verify.sh
  
  # Return to script directory
  cd "${SCRIPT_DIR}"
  
  log "Installation verified successfully."
}

#######################################
# Forcefully clean up all used ports
#######################################
force_cleanup_ports() {
  log "Forcefully cleaning up all required ports..."
  
  # Define the ports used by AIBrix
  PORTS=(9090 3000 8265 8000 8010)
  
  for PORT in "${PORTS[@]}"; do
    # Check if port is in use
    if [ "$OS" == "Darwin" ]; then
      # macOS command
      PORT_PID=$(lsof -i :$PORT -t 2>/dev/null)
    else
      # Linux command
      PORT_PID=$(ss -tulpn | grep ":$PORT " | awk '{print $7}' | cut -d"=" -f2 | cut -d"," -f1 2>/dev/null)
    fi
    
    if [ ! -z "$PORT_PID" ]; then
      log "Port $PORT is in use by process $PORT_PID. Forcefully terminating..."
      
      # Kill the process
      if [ "$OS" == "Darwin" ]; then
        # For macOS, lsof -t returns just the PID
        kill -9 $PORT_PID 2>/dev/null || true
      else
        # For Linux, we might have multiple PIDs
        for PID in $PORT_PID; do
          kill -9 $PID 2>/dev/null || true
        done
      fi
      
      # Verify port is free
      sleep 1
      if [ "$OS" == "Darwin" ]; then
        PORT_CHECK=$(lsof -i :$PORT -t 2>/dev/null)
      else
        PORT_CHECK=$(ss -tulpn | grep ":$PORT " 2>/dev/null)
      fi
      
      if [ -z "$PORT_CHECK" ]; then
        log "Successfully freed up port $PORT"
      else
        warning "Failed to free up port $PORT. This might cause issues."
      fi
    else
      log "Port $PORT is already available."
    fi
  done
  
  # Also check for any Docker containers that might be using these ports
  log "Checking for Docker containers using required ports..."
  for PORT in "${PORTS[@]}"; do
    CONTAINER_ID=$(docker ps -q -f "publish=$PORT")
    if [ ! -z "$CONTAINER_ID" ]; then
      log "Docker container $CONTAINER_ID is using port $PORT. Forcefully stopping..."
      docker stop $CONTAINER_ID
      sleep 1
    fi
  done
  
  # Check for any existing nvkind clusters and delete them
  log "Checking for existing nvkind clusters..."
  if command -v nvkind &> /dev/null; then
    CLUSTERS=$(nvkind cluster list 2>/dev/null | grep -v "No kind clusters found" || true)
    if [ ! -z "$CLUSTERS" ]; then
      log "Existing nvkind clusters found. Deleting them..."
      nvkind cluster delete || true
      sleep 2
    fi
  fi
  
  log "Port cleanup completed."
}

#######################################
# Check required ports
#######################################
check_required_ports() {
  log "Checking required ports..."
  
  # First, forcefully clean up all ports
  force_cleanup_ports
  
  # Define the ports used by AIBrix
  PORTS=(9090 3000 8265 8000)
  
  # Verify all ports are now available
  for PORT in "${PORTS[@]}"; do
    # Check if port is in use
    if [ "$OS" == "Darwin" ]; then
      # macOS command
      PORT_PID=$(lsof -i :$PORT -t 2>/dev/null)
    else
      # Linux command
      PORT_PID=$(ss -tulpn | grep ":$PORT " | awk '{print $7}' | cut -d"=" -f2 | cut -d"," -f1 2>/dev/null)
    fi
    
    if [ ! -z "$PORT_PID" ]; then
      error "Port $PORT is still in use by process $PORT_PID even after cleanup. Please check manually."
    else
      log "Port $PORT is available."
    fi
  done
  
  # Also check for any Docker containers that might be using these ports
  for PORT in "${PORTS[@]}"; do
    CONTAINER_ID=$(docker ps -q -f "publish=$PORT")
    if [ ! -z "$CONTAINER_ID" ]; then
      error "Docker container $CONTAINER_ID is still using port $PORT even after cleanup. Please check manually."
    fi
  done
  
  log "Port check completed. All required ports are available."
}

#######################################
# 3. Create an nvkind Cluster
#######################################
create_cluster() {
  log "Creating nvkind cluster..."
  
  # Check if nvkind is installed
  if ! command -v nvkind &> /dev/null; then
    # Attempt to install nvkind again
    log "nvkind not found. Attempting to install it now..."
    
    # Create local bin directory if it doesn't exist
    mkdir -p ~/.local/bin
    
    # Ensure ~/.local/bin is in PATH
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
      log "Adding ~/.local/bin to PATH..."
      echo 'export PATH=$HOME/.local/bin:$PATH' >> ~/.bashrc
      export PATH="$HOME/.local/bin:$PATH"
    fi
    
    # Download and install nvkind
    log "Downloading nvkind binary..."
    curl -L -o ~/nvkind-linux-amd64.tar.gz https://github.com/Jeffwan/kind-with-gpus-examples/releases/download/v0.1.0/nvkind-linux-amd64.tar.gz || error "Failed to download nvkind binary."
    log "Extracting nvkind binary..."
    tar -xzvf ~/nvkind-linux-amd64.tar.gz -C ~/.local/bin/ || error "Failed to extract nvkind binary."
    log "Setting up nvkind..."
    chmod +x ~/.local/bin/nvkind-linux-amd64 || error "Failed to make nvkind executable."
    mv ~/.local/bin/nvkind-linux-amd64 ~/.local/bin/nvkind || error "Failed to rename nvkind binary."
    
    # Verify nvkind is installed
    if ! command -v nvkind &> /dev/null; then
      error "Failed to install nvkind. Cannot create cluster."
    fi
    
    log "nvkind installed successfully."
  fi
  
  # Check if Docker is running
  if ! docker info &>/dev/null; then
    error "Docker is not running. Please start Docker and try again."
  fi
  
  # Verify nvkind is working correctly
  log "Verifying nvkind functionality..."
  if ! nvkind --help &>/dev/null; then
    warning "nvkind command seems to be installed but may not be working correctly."
    log "Attempting to continue anyway..."
  else
    log "nvkind is working correctly."
  fi
  
  # Check Docker memory and CPU resources
  DOCKER_MEM=$(docker info | grep "Total Memory" | awk '{print $3}')
  if [[ -n "$DOCKER_MEM" && "${DOCKER_MEM%.*}" -lt 8 ]]; then
    warning "Docker has less than 8GB of memory allocated. This might cause cluster creation issues."
    warning "Please increase Docker memory allocation to at least 8GB in Docker Desktop settings."
  fi
  
  # Check if there are any existing clusters and delete them
  log "Checking for existing nvkind clusters..."
  if command -v nvkind &> /dev/null; then
    CLUSTERS=$(nvkind cluster list 2>/dev/null | grep -v "No kind clusters found" || true)
    if [ ! -z "$CLUSTERS" ]; then
      log "Existing nvkind clusters found. Deleting them..."
      nvkind cluster delete || true
      sleep 5
    fi
  fi
  
  # Check for any existing Docker containers related to kind/nvkind and remove them
  log "Checking for existing kind/nvkind containers..."
  KIND_CONTAINERS=$(docker ps -a | grep -E 'kind|nvkind' | awk '{print $1}' || true)
  if [ ! -z "$KIND_CONTAINERS" ]; then
    log "Found existing kind/nvkind containers. Removing them..."
    docker ps -a | grep -E 'kind|nvkind' | awk '{print $1}' | xargs -r docker rm -f
    sleep 2
  fi
  
  # Use the default configuration
  CLUSTER_CONFIG="${AIBRIX_REPO_PATH}/hack/lambda-cloud/nvkind-cluster.yaml"
  
  # Create a Kubernetes cluster using nvkind with increased timeout
  log "Creating cluster with nvkind (this may take several minutes)..."
  cd "${AIBRIX_REPO_PATH}"
  
  # Try to create the cluster with retries
  MAX_RETRIES=3
  RETRY_COUNT=0
  SUCCESS=false
  
  while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$SUCCESS" = false ]; do
    if [ $RETRY_COUNT -gt 0 ]; then
      log "Retrying cluster creation (attempt $((RETRY_COUNT+1))/$MAX_RETRIES)..."
      # Clean up any failed attempts
      nvkind cluster delete || true
      sleep 10
    fi
    
    if nvkind cluster create --config-template="${CLUSTER_CONFIG}" --wait 5m; then
      SUCCESS=true
    else
      RETRY_COUNT=$((RETRY_COUNT+1))
      log "Cluster creation failed. Retry $RETRY_COUNT/$MAX_RETRIES."
      sleep 5
    fi
  done
  
  if [ "$SUCCESS" = false ]; then
    error "Failed to create Kubernetes cluster after $MAX_RETRIES attempts. Please check Docker settings and try again."
  fi
  
  # Verify cluster is running
  log "Verifying cluster nodes..."
  if ! kubectl get nodes; then
    error "Failed to get cluster nodes. Cluster creation may have failed."
  fi
  
  # Return to script directory
  cd "${SCRIPT_DIR}"
  
  log "Kubernetes cluster created successfully."
}

#######################################
# Fix kubectl configuration
#######################################
fix_kubectl_config() {
  log "Fixing kubectl configuration for NVkind cluster..."
  
  # Find the control-plane container
  CONTROL_PLANE_CONTAINER=$(docker ps --filter "name=control-plane" --format "{{.Names}}" | grep -E 'nvkind|kind' | head -n 1)
  
  if [ -z "$CONTROL_PLANE_CONTAINER" ]; then
    warning "Could not find control-plane container. Kubectl configuration may not work correctly."
    return 1
  fi
  
  log "Found control-plane container: $CONTROL_PLANE_CONTAINER"
  
  # Get the port mapping for the control-plane API server (usually 6443)
  API_PORT_MAPPING=$(docker port $CONTROL_PLANE_CONTAINER 6443/tcp | head -n 1)
  
  if [ -z "$API_PORT_MAPPING" ]; then
    warning "Could not find API port mapping for the control-plane container."
    warning "Trying alternative method to get port mapping..."
    
    # Alternative method to get port mapping
    API_PORT_MAPPING=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if eq $p "6443/tcp"}}{{range $conf}}127.0.0.1:{{.HostPort}}{{end}}{{end}}{{end}}' $CONTROL_PLANE_CONTAINER)
    
    if [ -z "$API_PORT_MAPPING" ]; then
      warning "Still could not find API port mapping. Using default port mapping."
      API_PORT_MAPPING="127.0.0.1:6443"
    fi
  fi
  
  # Extract host and port from mapping
  API_HOST=$(echo $API_PORT_MAPPING | cut -d':' -f1)
  API_PORT=$(echo $API_PORT_MAPPING | cut -d':' -f2)
  
  # If host is empty or 0.0.0.0, use 127.0.0.1
  if [ -z "$API_HOST" ] || [ "$API_HOST" = "0.0.0.0" ]; then
    API_HOST="127.0.0.1"
  fi
  
  log "Using API server address: $API_HOST:$API_PORT"
  
  # Extract cluster name from control-plane container name
  CLUSTER_NAME=$(echo $CONTROL_PLANE_CONTAINER | sed -E 's/-(control-plane|master).*$//')
  
  if [ -z "$CLUSTER_NAME" ]; then
    CLUSTER_NAME="nvkind"
    warning "Could not extract cluster name from container name. Using '$CLUSTER_NAME' as fallback."
  fi
  
  log "Cluster name: $CLUSTER_NAME"
  
  # Get kubeconfig from the container
  log "Extracting kubeconfig from control-plane container..."
  mkdir -p $HOME/.kube
  docker exec $CONTROL_PLANE_CONTAINER cat /etc/kubernetes/admin.conf > $HOME/nvkind-kubeconfig
  
  if [ ! -f "$HOME/nvkind-kubeconfig" ]; then
    warning "Failed to extract kubeconfig from container. Kubectl configuration may not work correctly."
    return 1
  fi
  
  # Modify the kubeconfig to use the correct server address
  log "Updating kubeconfig with correct server address..."
  SERVER_URL="https://${API_HOST}:${API_PORT}"
  
  # Use sed to replace the server URL in the kubeconfig
  if [ "$OS" == "Darwin" ]; then
    # macOS sed requires an empty string for -i
    sed -i '' -e "s|server:.*|server: ${SERVER_URL}|g" $HOME/nvkind-kubeconfig
  else
    # Linux sed works directly with -i
    sed -i "s|server:.*|server: ${SERVER_URL}|g" $HOME/nvkind-kubeconfig
  fi
  
  # Set KUBECONFIG environment variable to use this config
  export KUBECONFIG="$HOME/nvkind-kubeconfig"
  
  # Copy to the default location
  cp $HOME/nvkind-kubeconfig $HOME/.kube/config
  
  # Test if the configuration works
  log "Testing kubectl configuration..."
  if kubectl get nodes &>/dev/null; then
    log "Kubectl configuration updated successfully. You can now use kubectl commands."
  else
    warning "Kubectl configuration update succeeded but kubectl test failed. Manual configuration may be needed."
    kubectl config view
  fi
}

#######################################
# Fix NVIDIA device plugin issues
#######################################
fix_nvidia_device_plugin() {
  log "Checking for NVIDIA device plugin issues..."
  
  # Check if the device plugin pod is in error state
  DEVICE_PLUGIN_POD=$(kubectl get pods -n kube-system -l app=nvidia-device-plugin-daemonset -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  
  if [ -z "$DEVICE_PLUGIN_POD" ]; then
    log "No NVIDIA device plugin pod found. Attempting to manually label nodes..."
    
    # Get the worker node name
    WORKER_NODE=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}')
    
    if [ ! -z "$WORKER_NODE" ]; then
      # Manually label the node with GPU capacity as a workaround
      log "Manually labeling worker node with GPU capacity..."
      kubectl label node $WORKER_NODE nvidia.com/gpu.present=true --overwrite
      kubectl label node $WORKER_NODE nvidia.com/gpu.count=1 --overwrite
    fi
    
    return
  fi
  
  # Check the status of the pod
  POD_STATUS=$(kubectl get pod -n kube-system $DEVICE_PLUGIN_POD -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  
  if [[ "$POD_STATUS" != "Running" ]]; then
    log "NVIDIA device plugin pod is not running. Attempting to fix..."
    
    # Get the daemonset name
    DAEMONSET_NAME=$(kubectl get daemonset -n kube-system -l app=nvidia-device-plugin-daemonset -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "$DAEMONSET_NAME" ]; then
      warning "Could not find NVIDIA device plugin daemonset. Trying manual node labeling instead."
      
      # Get the worker node name
      WORKER_NODE=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}')
      
      if [ ! -z "$WORKER_NODE" ]; then
        # Manually label the node with GPU capacity as a workaround
        log "Manually labeling worker node with GPU capacity..."
        kubectl label node $WORKER_NODE nvidia.com/gpu.present=true --overwrite
        kubectl label node $WORKER_NODE nvidia.com/gpu.count=1 --overwrite
      fi
    else
      # Create a patch to modify the daemonset
      cat <<EOF > "${SCRIPT_DIR}/nvidia-device-plugin-patch.yaml"
spec:
  template:
    spec:
      containers:
      - name: nvidia-device-plugin
        env:
        - name: NVIDIA_VISIBLE_DEVICES
          value: all
        - name: NVIDIA_DRIVER_CAPABILITIES
          value: all
        - name: FAIL_ON_INIT_ERROR
          value: "false"
EOF
      
      # Apply the patch
      log "Patching NVIDIA device plugin daemonset..."
      kubectl patch daemonset -n kube-system $DAEMONSET_NAME --patch-file "${SCRIPT_DIR}/nvidia-device-plugin-patch.yaml"
      
      # Delete the pod to force recreation with the new configuration
      log "Deleting NVIDIA device plugin pod to force recreation..."
      kubectl delete pod -n kube-system $DEVICE_PLUGIN_POD
      
      # Wait for the new pod to be created
      log "Waiting for new NVIDIA device plugin pod to be created..."
      sleep 10
    fi
  else
    log "NVIDIA device plugin pod is running correctly."
  fi
  
  # Wait for GPUs to be exposed to the cluster
  log "Waiting for GPUs to be exposed to the cluster..."
  TIMEOUT=60  # Reduced timeout to 1 minute
  INTERVAL=10  # Check every 10 seconds
  ELAPSED=0
  
  while true; do
    NODE_GPU_CAPACITY=$(kubectl get nodes -o=jsonpath='{.items[*].status.capacity.nvidia\.com/gpu}' || echo "")
    
    if [ ! -z "$NODE_GPU_CAPACITY" ]; then
      log "GPUs are now available to the cluster: $NODE_GPU_CAPACITY"
      break
    fi
    
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
      warning "Timeout waiting for GPUs to be exposed to the cluster."
      
      # Get the worker node name
      WORKER_NODE=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}')
      
      if [ ! -z "$WORKER_NODE" ]; then
        # Manually label the node with GPU capacity as a last resort
        log "Manually labeling worker node with GPU capacity as a last resort..."
        kubectl label node $WORKER_NODE nvidia.com/gpu.present=true --overwrite
        kubectl label node $WORKER_NODE nvidia.com/gpu.count=1 --overwrite
      fi
      
      break
    fi
    
    log "Waiting for GPUs to be exposed to the cluster..."
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
  done
}

#######################################
# 4. Setup NVIDIA GPU Operator
#######################################
setup_gpu_operator() {
  log "Setting up NVIDIA GPU Operator..."
  
  # Run the setup script from AIBrix
  cd "${AIBRIX_REPO_PATH}"
  bash ./hack/lambda-cloud/setup.sh
  
  # Return to script directory
  cd "${SCRIPT_DIR}"
  
  # Wait for the GPU operator to initialize
  log "Waiting for NVIDIA GPU Operator to initialize (this may take a few minutes)..."
  
  # Check if GPU operator pods are already running in kube-system namespace
  if kubectl get pods -n kube-system -l app=gpu-operator &>/dev/null || kubectl get pods -n kube-system -l app=nvidia-device-plugin-daemonset &>/dev/null; then
    log "GPU operator pods detected in kube-system namespace. Using this namespace instead."
    GPU_OPERATOR_NAMESPACE="kube-system"
  else
    # Wait for the GPU operator namespace to be created
    TIMEOUT=120  # Reduced to 2 minutes timeout
    INTERVAL=10  # Check every 10 seconds
    ELAPSED=0
    
    while true; do
      # Check if the namespace exists
      if kubectl get namespace gpu-operator-resources &>/dev/null; then
        log "GPU operator namespace created. Waiting for pods to start..."
        GPU_OPERATOR_NAMESPACE="gpu-operator-resources"
        break
      fi
      
      # Check if the namespace exists with a different name
      if kubectl get namespace nvidia-gpu-operator &>/dev/null; then
        log "Found GPU operator namespace with different name (nvidia-gpu-operator). Using this namespace instead."
        # Update the namespace name for later checks
        GPU_OPERATOR_NAMESPACE="nvidia-gpu-operator"
        break
      fi
      
      # Check if GPU operator pods are running in kube-system namespace
      if kubectl get pods -n kube-system -l app=gpu-operator &>/dev/null || kubectl get pods -n kube-system -l app=nvidia-device-plugin-daemonset &>/dev/null; then
        log "GPU operator pods detected in kube-system namespace. Using this namespace instead."
        GPU_OPERATOR_NAMESPACE="kube-system"
        break
      fi
      
      if [[ $ELAPSED -ge $TIMEOUT ]]; then
        warning "Timeout waiting for GPU operator namespace to be created. Checking all namespaces for GPU operator pods..."
        
        # Check all namespaces for GPU operator pods
        GPU_PODS=$(kubectl get pods --all-namespaces | grep -E 'nvidia|gpu-operator' || echo "")
        
        if [ ! -z "$GPU_PODS" ]; then
          log "Found GPU-related pods in other namespaces:"
          echo "$GPU_PODS"
          
          # Extract the namespace from the first matching pod
          GPU_OPERATOR_NAMESPACE=$(echo "$GPU_PODS" | head -n 1 | awk '{print $1}')
          log "Using namespace: ${GPU_OPERATOR_NAMESPACE}"
        else
          warning "No GPU operator pods found in any namespace. Continuing anyway..."
          GPU_OPERATOR_NAMESPACE="kube-system"  # Default to kube-system
        fi
        break
      fi
      
      log "Waiting for GPU operator namespace to be created..."
      sleep $INTERVAL
      ELAPSED=$((ELAPSED + INTERVAL))
    done
  fi
  
  # Wait for the GPU operator pods to be running
  log "Checking for GPU operator pods in namespace: ${GPU_OPERATOR_NAMESPACE}..."
  TIMEOUT=120  # Reduced to 2 minutes timeout
  INTERVAL=10  # Check every 10 seconds
  ELAPSED=0
  
  while true; do
    # Check for nvidia-device-plugin pod
    DEVICE_PLUGIN_RUNNING=false
    if kubectl get pods -n ${GPU_OPERATOR_NAMESPACE} -l app=nvidia-device-plugin-daemonset &>/dev/null; then
      DEVICE_PLUGIN_POD=$(kubectl get pods -n ${GPU_OPERATOR_NAMESPACE} -l app=nvidia-device-plugin-daemonset -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
      if [ ! -z "$DEVICE_PLUGIN_POD" ]; then
        POD_STATUS=$(kubectl get pod -n ${GPU_OPERATOR_NAMESPACE} $DEVICE_PLUGIN_POD -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [[ "$POD_STATUS" == "Running" ]]; then
          DEVICE_PLUGIN_RUNNING=true
          log "NVIDIA device plugin pod is running."
        fi
      fi
    fi
    
    # Count running pods in the GPU operator namespace with nvidia or gpu labels
    RUNNING_PODS=$(kubectl get pods -n ${GPU_OPERATOR_NAMESPACE} 2>/dev/null | grep -E 'nvidia|gpu' | grep -c "Running" || echo "0")
    # Ensure RUNNING_PODS is a clean integer
    RUNNING_PODS=$(echo $RUNNING_PODS | tr -d ' \t\n\r')
    
    if [[ "$RUNNING_PODS" -gt 0 || "$DEVICE_PLUGIN_RUNNING" == "true" ]]; then
      log "GPU operator has $RUNNING_PODS pods running in namespace ${GPU_OPERATOR_NAMESPACE}."
      break
    fi
    
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
      warning "Timeout waiting for GPU operator pods to start. Continuing anyway..."
      break
    fi
    
    log "Waiting for GPU operator pods to start running..."
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
  done
  
  # Check if GPUs are available to the cluster
  NODE_GPU_CAPACITY=$(kubectl get nodes -o=jsonpath='{.items[*].status.capacity.nvidia\.com/gpu}' || echo "")
  
  if [ -z "$NODE_GPU_CAPACITY" ]; then
    warning "No GPUs appear to be available to the cluster. Attempting to fix NVIDIA device plugin issues..."
    
    # Try to fix NVIDIA device plugin issues
    fix_nvidia_device_plugin
    
    # Check again if GPUs are available
    NODE_GPU_CAPACITY=$(kubectl get nodes -o=jsonpath='{.items[*].status.capacity.nvidia\.com/gpu}' || echo "")
    
    if [ -z "$NODE_GPU_CAPACITY" ]; then
      warning "Still no GPUs available to the cluster. This might affect model deployment."
    else
      log "GPUs are now available to the cluster: $NODE_GPU_CAPACITY"
    fi
  else
    log "GPUs are available to the cluster: $NODE_GPU_CAPACITY"
  fi
    
  log "NVIDIA GPU Operator setup completed."
}

#######################################
# 5. Install AIBrix
#######################################
install_aibrix() {
  log "Installing AIBrix components..."
  
  # Install dependencies
  kubectl create -k "github.com/vllm-project/aibrix/config/dependency?ref=${AIBRIX_VERSION}"
  
  # Install core components
  kubectl create -k "github.com/vllm-project/aibrix/config/overlays/release?ref=${AIBRIX_VERSION}"
  
  # Verify AIBrix installation
  kubectl get pods -n aibrix-system
  
  log "AIBrix installation completed."
}

#######################################
# 6. Model Deployment
#######################################
deploy_model() {
  log "Deploying ${MODEL_NAME} model..."
  
  # Create directory for KV cache socket
  log "Creating directory for KV cache socket..."
  sudo mkdir -p /var/run/vineyard-kubernetes/default/aibrix-kvcache
  
  # Check if GPUs are available to the cluster
  log "Checking if GPUs are available to the cluster before deployment..."
  NODE_GPU_CAPACITY=$(kubectl get nodes -o=jsonpath='{.items[*].status.capacity.nvidia\.com/gpu}' || echo "")
  
  if [ -z "$NODE_GPU_CAPACITY" ]; then
    warning "No GPUs appear to be available to the cluster. Attempting to fix NVIDIA device plugin issues..."
    
    # Try to fix NVIDIA device plugin issues
    fix_nvidia_device_plugin
    
    # Check again if GPUs are available
    NODE_GPU_CAPACITY=$(kubectl get nodes -o=jsonpath='{.items[*].status.capacity.nvidia\.com/gpu}' || echo "")
    
    if [ -z "$NODE_GPU_CAPACITY" ]; then
      warning "Still no GPUs available to the cluster. Deployment may fail."
    else
      log "GPUs are now available to the cluster: $NODE_GPU_CAPACITY"
    fi
  else
    log "GPUs available to the cluster: $NODE_GPU_CAPACITY"
  fi
  
  # Apply the DeepSeek model deployment
  log "Applying ${MODEL_NAME} model deployment..."
  kubectl apply -f "${SCRIPT_DIR}/${MODEL_NAME}.yaml"
  
  # Wait for the deployment to be ready
  log "Waiting for ${MODEL_NAME} deployment to be ready (this may take several minutes)..."
  kubectl wait --for=condition=available --timeout=600s deployment/${MODEL_NAME} || true
  
  # Wait for the pod to be running
  log "Waiting for the pod to be in Running state..."
  POD_NAME=$(kubectl get pods -l model.aibrix.ai/name=${MODEL_NAME} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  
  if [ ! -z "$POD_NAME" ]; then
    # Wait for the pod to be in Running state with a timeout
    TIMEOUT=300  # 5 minutes timeout
    INTERVAL=10  # Check every 10 seconds
    ELAPSED=0
    
    while true; do
      POD_STATUS=$(kubectl get pod $POD_NAME -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
      if [[ "$POD_STATUS" == "Running" ]]; then
        log "Pod $POD_NAME is now running."
        break
      fi
      
      if [[ $ELAPSED -ge $TIMEOUT ]]; then
        warning "Timeout waiting for pod to be in Running state. Current status: $POD_STATUS"
        kubectl describe pod $POD_NAME
        break
      fi
      
      log "Pod $POD_NAME is in $POD_STATUS state. Waiting..."
      sleep $INTERVAL
      ELAPSED=$((ELAPSED + INTERVAL))
    done
  fi
  
  # Check if port 8010 is available for port forwarding
  if [ "$OS" == "Darwin" ]; then
    PORT_CHECK=$(lsof -i :8010 -t 2>/dev/null)
  else
    PORT_CHECK=$(ss -tulpn | grep ":8010 " 2>/dev/null)
  fi
  
  # If port 8010 is in use, error out
  if [ ! -z "$PORT_CHECK" ]; then
    error "Port 8010 is already in use. Please free up this port before running the script."
  fi
  
  # Set up port forwarding with the fixed port
  PORT_FORWARD=8010
  log "Setting up port forwarding to access the model..."
  # Forward directly to the pod instead of the service
  kubectl port-forward pod/${POD_NAME} ${PORT_FORWARD}:8000 &
  PORT_FORWARD_PID=$!
  
  # Wait for port forwarding to be established
  sleep 5
  
  # Check if port forwarding is working
  if [ "$OS" == "Darwin" ]; then
    PORT_FORWARD_CHECK=$(lsof -i :${PORT_FORWARD} -t 2>/dev/null)
  else
    PORT_FORWARD_CHECK=$(ss -tulpn | grep ":${PORT_FORWARD} " 2>/dev/null)
  fi
  
  if [ -z "$PORT_FORWARD_CHECK" ]; then
    warning "Port forwarding does not appear to be working. The benchmark may fail."
  else
    log "${MODEL_NAME} is deployed and accessible at localhost:${PORT_FORWARD} (directly forwarded to pod ${POD_NAME})"
  fi
  
  # Save the port forwarding PID for later cleanup
  echo $PORT_FORWARD_PID > "${SCRIPT_DIR}/.port_forward.pid"
}

#######################################
# Cleanup function
#######################################
cleanup() {
  log "Cleanup process starting..."
  
  # Ask if user wants to perform cleanup
  read -p "Do you want to perform cleanup? This will stop port forwarding but keep the cluster running. (y/n): " perform_cleanup
  if [[ "$perform_cleanup" != "y" && "$perform_cleanup" != "Y" ]]; then
    log "Cleanup skipped. The model deployment and port forwarding will continue to run."
    log "You can access the model at localhost:8010"
    if [ -f "${SCRIPT_DIR}/.benchmark.pid" ]; then
      log "Benchmark is running in the background. You can monitor it with: tail -f ${BENCHMARK_OUTPUT_DIR}/${MODEL_NAME}-*.log"
    fi
    log "To clean up later, you can manually stop port forwarding and delete the cluster if needed."
    exit 0
  fi
  
  # Kill benchmark process if running
  if [ -f "${SCRIPT_DIR}/.benchmark.pid" ]; then
    log "Stopping benchmark process..."
    kill $(cat "${SCRIPT_DIR}/.benchmark.pid") 2>/dev/null || true
    rm "${SCRIPT_DIR}/.benchmark.pid"
    log "Benchmark process stopped."
  fi
  
  # Kill port forwarding if running
  if [ -f "${SCRIPT_DIR}/.port_forward.pid" ]; then
    log "Stopping port forwarding..."
    kill $(cat "${SCRIPT_DIR}/.port_forward.pid") 2>/dev/null || true
    rm "${SCRIPT_DIR}/.port_forward.pid"
    log "Port forwarding stopped."
  fi
  
  # Ask if user wants to delete the cluster
  read -p "Do you want to delete the Kubernetes cluster? This will remove all deployed models and resources. (y/n): " delete_cluster
  if [[ "$delete_cluster" == "y" || "$delete_cluster" == "Y" ]]; then
    log "Deleting Kubernetes cluster..."
    
    # First, try to delete the cluster using nvkind
    if command -v nvkind &> /dev/null; then
      nvkind cluster delete || true
      
      # Wait a moment for the deletion to complete
      sleep 5
      
      # Now check if any containers related to nvkind/kind are still running
      KIND_CONTAINERS=$(docker ps -a | grep -E 'kind|nvkind' | awk '{print $1}' || echo "")
      if [ ! -z "$KIND_CONTAINERS" ]; then
        log "Some kind/nvkind containers are still present. Removing them..."
        docker ps -a | grep -E 'kind|nvkind' | awk '{print $1}' | xargs -r docker rm -f 2>/dev/null || true
      fi
      
      # Remove any dangling volumes
      log "Removing dangling volumes..."
      docker volume prune -f
      
      log "Kubernetes cluster deleted."
    else
      warning "nvkind command not found. Unable to delete the cluster properly."
    fi
  else
    log "Kubernetes cluster is still running. You can delete it later with: nvkind cluster delete"
  fi
  
  # Force cleanup all ports to ensure they're free for the next run
  log "Forcefully cleaning up all ports for the next run..."
  force_cleanup_ports
  
  log "Cleanup completed."
}

#######################################
# Check benchmark status
#######################################
check_benchmark_status() {
  log "Checking benchmark status..."
  
  # Use the script directory
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  
  # Check if benchmark PID file exists
  if [ ! -f "${SCRIPT_DIR}/.benchmark.pid" ]; then
    log "No benchmark process found. It may not have started or has already completed."
    return 1
  fi
  
  # Get the benchmark PID
  BENCHMARK_PID=$(cat "${SCRIPT_DIR}/.benchmark.pid")
  
  # Define the results file path
  RESULTS_DIR="${SCRIPT_DIR}/profiles/results"
  RESULT_FILE="${RESULTS_DIR}/${MODEL_NAME}.jsonl"
  
  # Check if the process is still running
  if ps -p $BENCHMARK_PID > /dev/null; then
    log "Benchmark process (PID: $BENCHMARK_PID) is still running."
    
    # Find the most recent log file
    LATEST_LOG=$(ls -t ${SCRIPT_DIR}/${MODEL_NAME}-*.log 2>/dev/null | head -1)
    
    if [ -n "$LATEST_LOG" ]; then
      # Get the file size
      LOG_SIZE=$(du -h "$LATEST_LOG" | cut -f1)
      
      # Get the last few lines to show progress
      log "Current log file: $LATEST_LOG (Size: $LOG_SIZE)"
      log "Recent benchmark activity:"
      tail -n 10 "$LATEST_LOG" | grep -v "^$" | head -n 5
      
      # Count completed benchmark runs (each line in the log file represents a completed run)
      COMPLETED_RUNS=$(grep -c "run benchmark with" "$LATEST_LOG")
      log "Completed benchmark runs so far: $COMPLETED_RUNS"
      
      # Check if results file exists and show its size
      if [ -f "$RESULT_FILE" ]; then
        RESULT_SIZE=$(du -h "$RESULT_FILE" | cut -f1)
        log "Results file exists: $RESULT_FILE (Size: $RESULT_SIZE)"
      else
        log "Results file not created yet"
      fi
      
      # Show how to monitor the benchmark
      log "To monitor the benchmark in real-time, run: tail -f $LATEST_LOG"
    else
      log "No log file found. The benchmark may have just started."
    fi
    
    return 0
  else
    # Process is not running
    log "Benchmark process is not running. It has completed or was terminated."
    
    # Find the most recent log file
    LATEST_LOG=$(ls -t ${SCRIPT_DIR}/${MODEL_NAME}-*.log 2>/dev/null | head -1)
    
    if [ -n "$LATEST_LOG" ]; then
      # Get the file size
      LOG_SIZE=$(du -h "$LATEST_LOG" | cut -f1)
      
      # Check if the log contains "Benchmarking finished" message
      if grep -q "Benchmarking finished" "$LATEST_LOG"; then
        log "Benchmark completed successfully!"
      else
        log "Benchmark may have terminated unexpectedly. Check the log file for errors."
      fi
      
      log "Log file: $LATEST_LOG (Size: $LOG_SIZE)"
      log "Last few lines of the log:"
      tail -n 5 "$LATEST_LOG"
      
      # Check if results file exists
      if [ -f "$RESULT_FILE" ]; then
        RESULT_SIZE=$(du -h "$RESULT_FILE" | cut -f1)
        log "Results file created: $RESULT_FILE (Size: $RESULT_SIZE)"
        
        # Show a sample of the results
        log "Sample of benchmark results:"
        head -n 3 "$RESULT_FILE"
      else
        log "No results file found at $RESULT_FILE"
      fi
      
      # Count completed benchmark runs
      COMPLETED_RUNS=$(grep -c "run benchmark with" "$LATEST_LOG")
      log "Total completed benchmark runs: $COMPLETED_RUNS"
    else
      log "No log file found. The benchmark may not have generated any output."
    fi
    
    # Clean up the PID file
    rm -f "${SCRIPT_DIR}/.benchmark.pid"
    
    return 2
  fi
}

#######################################
# Wait for benchmark to complete
#######################################
wait_for_benchmark() {
  log "Waiting for benchmark to complete..."
  
  # Use the script directory
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  
  # Check if benchmark PID file exists
  if [ ! -f "${SCRIPT_DIR}/.benchmark.pid" ]; then
    log "No benchmark process found. It may not have started or has already completed."
    return 1
  fi
  
  # Get the benchmark PID
  BENCHMARK_PID=$(cat "${SCRIPT_DIR}/.benchmark.pid")
  
  # Find the log file
  LATEST_LOG=$(ls -t ${SCRIPT_DIR}/${MODEL_NAME}-*.log 2>/dev/null | head -1)
  
  if [ -z "$LATEST_LOG" ]; then
    log "No log file found. Cannot monitor benchmark progress."
    return 1
  fi
  
  # Define the results file path
  RESULTS_DIR="${SCRIPT_DIR}/profiles/results"
  RESULT_FILE="${RESULTS_DIR}/${MODEL_NAME}.jsonl"
  
  log "Monitoring benchmark progress. Press Ctrl+C to stop monitoring (benchmark will continue running)."
  log "Log file: $LATEST_LOG"
  log "Results will be saved to: $RESULT_FILE"
  
  # Wait for the process to complete while showing progress
  while ps -p $BENCHMARK_PID > /dev/null; do
    # Show the last few lines of the log file
    echo "--- Current benchmark progress ($(date)) ---"
    tail -n 5 "$LATEST_LOG" | grep -v "^$"
    
    # Count completed benchmark runs
    COMPLETED_RUNS=$(grep -c "run benchmark with" "$LATEST_LOG")
    echo "Completed benchmark runs so far: $COMPLETED_RUNS"
    
    # Check if results file exists and show its size
    if [ -f "$RESULT_FILE" ]; then
      RESULT_SIZE=$(du -h "$RESULT_FILE" | cut -f1)
      echo "Results file size: $RESULT_SIZE"
    else
      echo "Results file not created yet"
    fi
    
    # Wait for a while before checking again
    echo "Checking again in 30 seconds... (Press Ctrl+C to stop monitoring)"
    sleep 30
  done
  
  log "Benchmark process has completed!"
  
  # Show final status
  if grep -q "Benchmarking finished" "$LATEST_LOG"; then
    log "Benchmark completed successfully!"
  else
    log "Benchmark may have terminated unexpectedly. Check the log file for errors."
  fi
  
  # Check if results file exists
  if [ -f "$RESULT_FILE" ]; then
    RESULT_SIZE=$(du -h "$RESULT_FILE" | cut -f1)
    log "Results file created: $RESULT_FILE (Size: $RESULT_SIZE)"
    
    # Show a sample of the results
    log "Sample of benchmark results:"
    head -n 3 "$RESULT_FILE"
  else
    log "No results file found at $RESULT_FILE"
  fi
  
  # Count total completed benchmark runs
  COMPLETED_RUNS=$(grep -c "run benchmark with" "$LATEST_LOG")
  log "Total completed benchmark runs: $COMPLETED_RUNS"
  
  # Clean up the PID file
  rm -f "${SCRIPT_DIR}/.benchmark.pid"
  
  return 0
}

#######################################
# Run benchmark directly
#######################################
run_benchmark_directly() {
  log "Running benchmark directly..."
  
  # Use the script directory for benchmark results instead of a fixed path
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  
  # Create a timestamp for the log file
  DATETIME=$(date +"%Y%m%d_%H%M%S")
  LOG_FILE="${SCRIPT_DIR}/${MODEL_NAME}-${DATETIME}.log"
  
  # Create the log file with the current user permissions
  touch "${LOG_FILE}" && chmod 666 "${LOG_FILE}"
  
  # Define results directory path (but don't create it)
  RESULTS_DIR="${SCRIPT_DIR}/profiles/results"
  
  # Check if port forwarding is active
  PORT_CHECK=$(ss -tulpn | grep ":8010 " 2>/dev/null || lsof -i :8010 -t 2>/dev/null)
  if [ -z "$PORT_CHECK" ]; then
    warning "Port 8010 is not in use. Setting up port forwarding..."
    
    # Check if there's a pod running
    POD_NAME=$(kubectl get pods -l model.aibrix.ai/name=${MODEL_NAME} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ ! -z "$POD_NAME" ]; then
      log "Found model pod: $POD_NAME. Setting up port forwarding..."
      kubectl port-forward pod/${POD_NAME} 8010:8000 &
      PORT_FORWARD_PID=$!
      
      # Save the port forwarding PID for later cleanup
      echo $PORT_FORWARD_PID > "${SCRIPT_DIR}/.port_forward.pid"
      
      # Wait for port forwarding to be established
      sleep 5
      
      # Check if port forwarding is working
      PORT_FORWARD_CHECK=$(ss -tulpn | grep ":8010 " 2>/dev/null || lsof -i :8010 -t 2>/dev/null)
      
      if [ -z "$PORT_FORWARD_CHECK" ]; then
        error "Port forwarding failed. Cannot access the model."
      else
        log "Port forwarding established. Model is accessible at localhost:8010"
      fi
    else
      error "No model pod found. Please run the setup script first."
    fi
  else
    log "Port 8010 is in use. Assuming model is accessible."
  fi
  
  # Create the results directory if it doesn't exist
  mkdir -p "${RESULTS_DIR}"
  
  # Define the result file path
  RESULT_FILE="${RESULTS_DIR}/${MODEL_NAME}.jsonl"
  
  # Run the benchmark using docker directly with host network
  log "Running benchmark directly. Log file: ${LOG_FILE}"
  log "Results will be saved to: ${RESULT_FILE}"
  
  # Run the container with the benchmark command - map the default output directory without specifying --output
  docker run --rm --network=host \
    -v "${RESULTS_DIR}:/usr/local/lib/python3.11/site-packages/aibrix/gpu_optimizer/optimizer/profiling/result" \
    -e "MODEL_NAME=${MODEL_NAME}" \
    -e "LLM_API_KEY=${API_KEY}" \
    -e "LLM_API_BASE=http://localhost:8010" \
    --entrypoint bash \
    aibrix/runtime:nightly \
    -c "aibrix_benchmark -m ${MODEL_NAME} -o ${MODEL_NAME} --input-start 4 --input-limit 8196 --output-start 4 --output-limit 2048 --rate-start 1 --rate-limit 64 --output /usr/local/lib/python3.11/site-packages/aibrix/gpu_optimizer/optimizer/profiling/result/${MODEL_NAME}.jsonl" > "${LOG_FILE}" 2>&1 &
  
  BENCHMARK_PID=$!
  
  # Save the benchmark PID for later reference
  echo $BENCHMARK_PID > "${SCRIPT_DIR}/.benchmark.pid"
  
  log "Benchmark started in background. Log file: ${LOG_FILE}"
  log "Results will be saved to: ${RESULT_FILE}"
  
  # Update BENCHMARK_OUTPUT_DIR for wait_for_benchmark function
  BENCHMARK_OUTPUT_DIR="${SCRIPT_DIR}"
}

#######################################
# Main execution
#######################################
main() {
  log "Starting AIBrix setup..."
  
  # Register cleanup function to run on script exit, but only if not interrupted
  # This prevents automatic cleanup when the user presses Ctrl+C
  trap 'log "Script interrupted. Starting controlled cleanup..."; cleanup' EXIT
  
  # Also handle Ctrl+C (SIGINT) separately to allow for a clean exit
  trap 'log "Received interrupt signal. Exiting without automatic cleanup."; trap - EXIT; exit 1' INT
  
  # Check system requirements first
  check_system_requirements || {
    warning "System requirements check had issues. Proceeding anyway..."
  }
  
  # Execute each step with error handling
  install_dependencies || {
    warning "Failed to install dependencies. Attempting to continue..."
  }
  
  verify_installation || {
    warning "Installation verification failed. Attempting to continue..."
  }
  
  check_required_ports || {
    error "Required ports check failed. Please fix the issues and try again."
  }
  
  create_cluster || {
    error "Failed to create Kubernetes cluster. Please check the logs and try again."
  }
  
  # Fix kubectl configuration before continuing with other steps
  fix_kubectl_config || {
    warning "Failed to fix kubectl configuration. Attempting to continue anyway..."
  }
  
  setup_gpu_operator || {
    warning "GPU operator setup may have issues. Attempting to continue..."
  }
  
  install_aibrix || {
    warning "AIBrix installation may have issues. Attempting to continue..."
  }
  
  deploy_model || {
    warning "Model deployment may have issues. Please check the logs."
  }
  
  log "AIBrix setup with ${MODEL_NAME} model completed successfully."
  log "The model is now accessible at localhost:8010"
  
  # Run benchmark directly after model deployment
  log "Starting benchmark process..."
  run_benchmark_directly
  
  # If benchmark is running, provide information about how to check its status
  if [ -f "${SCRIPT_DIR}/.benchmark.pid" ]; then
    log "Benchmark is running in the background."
    log "You can check the benchmark status with: ${SCRIPT_DIR}/setup-environment.sh check-benchmark"
    log "You can wait for the benchmark to complete with: ${SCRIPT_DIR}/setup-environment.sh wait-benchmark"
  fi
  
  log "Press Ctrl+C to exit without cleanup, or let the script continue to the cleanup phase."
  
  # Wait for user to review the deployment before proceeding to cleanup
  log "Waiting 10 seconds before proceeding to cleanup phase..."
  sleep 10
}

# Main execution
if [ "$1" = "cleanup" ]; then
  cleanup
elif [ "$1" = "check-benchmark" ]; then
  check_benchmark_status
elif [ "$1" = "wait-benchmark" ]; then
  wait_for_benchmark
elif [ "$1" = "run-benchmark" ]; then
  run_benchmark_directly
elif [ "$1" = "fix-kubectl" ]; then
  fix_kubectl_config
else
  main
fi