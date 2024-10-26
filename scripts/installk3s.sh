#!/bin/bash
# Redirect all output to a file
# Save the original stdout and stderr
exec 3>&1 4>&2

exec >installK3s.log
exec 2>&1

# Check if resourceGroup parameter is provided
if [ -z "$1" ]; then
  echo "Error: Please provide the resource group name and custom location object id as parameters."
  exit 1
fi
resourceGroup=$1
objectId=$2

sudo apt-get update

# Set k3 deployment variables
export K3S_VERSION="1.29.6+k3s2" # Do not change!

# Installing Azure CLI & Azure Arc extensions
while [ $retry_count -lt $max_retries ]; do
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
    if [ $? -eq 0 ]; then
        success=true
        break
    else
        echo "Failed to install Azure CLI. Retrying (Attempt $((retry_count+1)))..."
        retry_count=$((retry_count+1))
        sleep 10
    fi
done

if [ "$success" = false ]; then
    echo "Error: Failed to install Azure CLI after $max_retries attempts."
    exit 1
fi
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

az -v

# Installing Rancher K3s cluster (single control plane)
echo ""
echo "Installing Rancher K3s cluster"
echo ""
publicIp=$(hostname -i)
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --disable traefik --disable servicelb --node-ip ${publicIp} --node-external-ip ${publicIp} --bind-address ${publicIp} --tls-san ${publicIp}" INSTALL_K3S_VERSION=v${K3S_VERSION} K3S_KUBECONFIG_MODE="644" sh -
if [[ $? -ne 0 ]]; then
    echo "ERROR: K3s installation failed"
    exit 1
fi

# Renaming default context to k3s cluster name
context=edge-k3s
sudo kubectl config rename-context default $context --kubeconfig /etc/rancher/k3s/k3s.yaml
sudo mkdir $HOME/.kube
sudo cp /etc/rancher/k3s/k3s.yaml $HOME/.kube/config

# Installing Helm 3
echo ""
echo "Installing Helm"
echo ""
sudo snap install helm --classic
if [[ $? -ne 0 ]]; then
    echo "ERROR: Helm installation failed"
    exit 1
fi

echo ""
echo "Making sure Rancher K3s cluster is ready..."
echo ""
sudo kubectl wait --for=condition=Available --timeout=60s --all deployments -A >/dev/null
sudo kubectl get nodes -o wide 

# Prep cluster for AIO
echo fs.inotify.max_user_instances=8192 | sudo tee -a /etc/sysctl.conf
echo fs.inotify.max_user_watches=524288 | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
echo fs.file-max = 100000 | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Configure Azure CLI to automatically install extensions
az config set extension.use_dynamic_install=yes_without_prompt

az login --identity

# Get the VM name from the Azure Instance Metadata Service
vm_name=$(curl -H Metadata:true "http://169.254.169.254/metadata/instance/compute/name?api-version=2021-02-01&format=text")
clusterName="Arc-K3s"

# Arc enable cluster using managed identity
max_retries=5
retry_count=0
success=false

while [ $retry_count -lt $max_retries ]; do
    az connectedk8s connect --name $clusterName --resource-group $resourceGroup --kube-config $HOME/.kube/config --enable-oidc-issuer --enable-workload-identity
    if [ $? -eq 0 ]; then
        success=true
        break
    else
        echo "Failed to onboard cluster to Azure Arc. Retrying (Attempt $((retry_count+1)))..."
        retry_count=$((retry_count+1))
        sleep 10
    fi
done

if [ "$success" = false ]; then
    echo "Error: Failed to onboard the cluster to Azure Arc after $max_retries attempts."
    exit 1
fi

oidcIssuerUri=$(az connectedk8s show --resource-group $resourceGroup --name $clusterName --query oidcIssuerProfile.issuerUrl --output tsv)
configFile="/etc/rancher/k3s/config.yaml"
cat <<EOF > $configFile
kube-apiserver-arg:
 - service-account-issuer=$oidcIssuerUri
 - service-account-max-token-expiration=24h
EOF

# Enabling custom locations
az connectedk8s enable-features -n $clusterName -g $resourceGroup --custom-locations-oid $objectId --features cluster-connect custom-locations

systemctl restart k3s

# Prep AIO deploy
randomstr=$(head /dev/urandom | tr -dc a-z0-9 | head -c 8)
$vault=kv${randomstr}
az keyvault create --enable-rbac-authorization --name $kv --resource-group $resourceGroup

sa=ig24prel18${randomstr}
az storage account create --name $sa --resource-group $resourceGroup --enable-hierarchical-namespace

$schemaName=schema${randomstr}
$namespace="Ignite"
az iot ops schema registry create --name $schemaName --resource-group $resourceGroup --registry-namespace $namespace --sa-resource-id $(az storage account show --name $sa --resource-group $resourceGroup -o tsv --query id)


exec 1>&3 2>&4 # Further commands will now output to the original stdout and stderr and not the log file

exit 0