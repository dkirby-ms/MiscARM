#!/bin/bash
sudo apt-get update

# Set k3 deployment variables
export K3S_VERSION="1.29.6+k3s2" # Do not change!

# Installing Azure CLI & Azure Arc extensions
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

az -v

# Installing Rancher K3s cluster (single control plane)
echo ""
echo "Installing Rancher K3s cluster"
echo ""
publicIp=$(hostname -i)
sudo mkdir ~/.kube
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --disable traefik --disable servicelb --node-ip ${publicIp} --node-external-ip ${publicIp} --bind-address ${publicIp} --tls-san ${publicIp}" INSTALL_K3S_VERSION=v${K3S_VERSION} K3S_KUBECONFIG_MODE="644" sh -
if [[ $? -ne 0 ]]; then
    echo "ERROR: K3s installation failed"
    exit 1
fi

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
sudo kubectl get nodes -o wide | expand | awk 'length($0) > length(longest) { longest = $0 } { lines[NR] = $0 } END { gsub(/./, "=", longest); print "/=" longest "=\\"; n = length(longest); for(i = 1; i <= NR; ++i) { printf("| %s %*s\n", lines[i], n - length(lines[i]) + 1, "|"); } print "\\=" longest "=/" }'

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
vm_resource_group=$(az vm show --query resourceGroup --name "$vm_name" --output tsv)
clusterName="Arc-K3s"
# Arc enable cluster using managed identity
az connectedk8s connect --name $clusterName --resource-group $vm_resource_group --enable-oidc-issuer --enable-workload-identity

oidcIssuerUri=$(az connectedk8s show --resource-group $vm_resource_group --name $clusterName --query oidcIssuerProfile.issuerUrl --output tsv)
configFile="/etc/rancher/k3s/config.yaml"
cat <<EOF > $configFile
kube-apiserver-arg:
 - service-account-issuer=$oidcIssuerUri
 - service-account-max-token-expiration=24h
EOF

# Enabling custom locations
objectId=$(az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv)
az connectedk8s enable-features -n $clusterName -g $vm_resource_group --custom-locations-oid $objectId --features cluster-connect custom-locations

exit 0