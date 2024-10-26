#sudo apt-get update && sudo apt-get dist-upgrade --assume-yes
sudo apt-get update

sudo apt-get install apt-transport-https ca-certificates curl gnupg lsb-release -y
sudo mkdir -p /etc/apt/keyrings
curl -sLS https://packages.microsoft.com/keys/microsoft.asc |   gpg --dearmor | sudo tee /etc/apt/keyrings/microsoft.gpg > /dev/null
sudo chmod go+r /etc/apt/keyrings/microsoft.gpg
AZ_DIST=$(lsb_release -cs)
echo "Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: ${AZ_DIST}
Components: main
Architectures: $(dpkg --print-architecture)
Signed-by: /etc/apt/keyrings/microsoft.gpg" | sudo tee /etc/apt/sources.list.d/azure-cli.sources
sudo apt-get update
sudo apt-get install azure-cli -y

az extension add --upgrade --name azure-iot-ops
az extension add --upgrade --name connectedk8s

curl -sfL https://get.k3s.io | sh -
sudo apt-get update
# apt-transport-https may be a placeholder package; if so, you can skip that package
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg
# If the folder `/etc/apt/keyrings` does not exist, it should be created before the curl command, read the note below.
# sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg # allow unprivileged APT programs to read this keyring
# This overwrites any existing configuration in /etc/apt/sources.list.d/kubernetes.list
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list   # helps tools such as command-not-found to work correctly
sudo apt-get update
sudo apt-get install -y kubectl

curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
sudo apt-get install apt-transport-https --yes
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt-get update
sudo apt-get install helm -y

mkdir ~/.kube
sudo KUBECONFIG=~/.kube/config:/etc/rancher/k3s/k3s.yaml kubectl config view --flatten > ~/.kube/merged
mv ~/.kube/merged ~/.kube/config
chmod  0600 ~/.kube/config
export KUBECONFIG=~/.kube/config
#switch to k3s context
kubectl config use-context default
sudo chmod 644 /etc/rancher/k3s/k3s.yaml

echo fs.inotify.max_user_instances=8192 | sudo tee -a /etc/sysctl.conf
echo fs.inotify.max_user_watches=524288 | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

echo fs.file-max = 100000 | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

az login
az provider register -n "Microsoft.ExtendedLocation"
az provider register -n "Microsoft.Kubernetes"
az provider register -n "Microsoft.KubernetesConfiguration"
az provider register -n "Microsoft.IoTOperations"
az provider register -n "Microsoft.DeviceRegistry"
az provider register -n "Microsoft.SecretSyncController"
# Azure region where the created resource group will be located
export LOCATION="eastus2"
# Name of a new resource group to create which will hold the Arc-enabled cluster and Azure IoT Operations resources
export RESOURCE_GROUP="rg-Edge"
# Name of the Arc-enabled cluster to create in your resource group
export CLUSTER_NAME="arc-k3s"
max_retries=5
retry_count=0
success=false
while [ $retry_count -lt $max_retries ]; do
    az connectedk8s connect --name $CLUSTER_NAME -l $LOCATION --resource-group $RESOURCE_GROUP --enable-oidc-issuer --enable-workload-identity
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

export ISSUER_URL_ID=$(az connectedk8s show --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --query oidcIssuerProfile.issuerUrl --output tsv)

#Enabling Service Account in k3s:
{
  echo "kube-apiserver-arg:"
  echo " - service-account-issuer=$ISSUER_URL_ID"
  echo " - service-account-max-token-expiration=24h"
} | sudo tee -a /etc/rancher/k3s/config.yaml > /dev/null

export OBJECT_ID=$(az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv)
az connectedk8s enable-features -n $CLUSTER_NAME -g $RESOURCE_GROUP --custom-locations-oid $OBJECT_ID --features cluster-connect custom-locations

sudo systemctl restart k3s
az iot ops verify-host

AKV_NAME="akv-Edge"
az keyvault create --enable-rbac-authorization --name $AKV_NAME --resource-group $RESOURCE_GROUP
export AKV_ID=$(az keyvault show --name $AKV_NAME --resource-group $RESOURCE_GROUP -o tsv --query id)

randomstr=$(head /dev/urandom | tr -dc a-z0-9 | head -c 8)
sa=ig24prel18${randomstr}
az storage account create --name $sa --resource-group $RESOURCE_GROUP --enable-hierarchical-namespace

schemaName=schema${randomstr}
az iot ops schema registry create --name $schemaName --resource-group $RESOURCE_GROUP --registry-namespace $sa --sa-resource-id $(az storage account show --name $sa --resource-group $RESOURCE_GROUP -o tsv --query id)
export SCHEMA_REGISTRY_RESOURCE_ID=$(az iot ops schema registry show --name $schemaName --resource-group $RESOURCE_GROUP -o tsv --query id)

az iot ops init --cluster $CLUSTER_NAME --resource-group $RESOURCE_GROUP --sr-resource-id $SCHEMA_REGISTRY_RESOURCE_ID

AIO_DEPLOYMENT_NAME="aio-edge"
USERASSIGNED_NAME="edge-identity"
CLOUDASSIGNED_NAME="cloud-identity"
az iot ops create --name $AIO_DEPLOYMENT_NAME --cluster $CLUSTER_NAME --resource-group $RESOURCE_GROUP --enable-rsync true --add-insecure-listener true
az identity create --name $USERASSIGNED_NAME --resource-group $RESOURCE_GROUP
export USERASSIGNED_ID=$(az identity show --name $USERASSIGNED_NAME --resource-group $RESOURCE_GROUP -o tsv --query id)

az iot ops secretsync enable --name $AIO_DEPLOYMENT_NAME --resource-group $RESOURCE_GROUP --mi-user-assigned $USERASSIGNED_ID --kv-resource-id $AKV_ID
az identity create --name $CLOUDASSIGNED_NAME --resource-group $RESOURCE_GROUP
export CLOUDASSIGNED_ID=$(az identity show --name $CLOUDASSIGNED_NAME --resource-group $RESOURCE_GROUP -o tsv --query id)

az iot ops identity assign --name $AIO_DEPLOYMENT_NAME --resource-group $RESOURCE_GROUP --mi-user-assigned $CLOUDASSIGNED_ID


