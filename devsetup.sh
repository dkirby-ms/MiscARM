#!/bin/bash
resourceGroup="rg-Edge"
az group create -g $resourceGroup -l eastus2

objectId=$(az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv)

subid="608937df-4e8f-4dc5-8bc6-16f30646ebd9"

az vm create -g $resourceGroup \
--name vm-Edge \
--image Ubuntu2204 \
--size Standard_d16s_v5 \
--assign-identity \
--role "Owner" \
--scope "/subscriptions/$subid/resourcegroups/rg-Edge" \
--generate-ssh-keys

# Get the managed identity principal ID
# identity_principal_id=$(az vm identity show --resource-group $resourceGroup --name $vmName --query principalId --output tsv)
# identity_object_id=$(az ad sp show --id $identity_principal_id --query objectId --output tsv)
# az role assignment create --assignee $identity_object_id --role "Directory Reader" --scope "/"

az vm extension set \
--resource-group rg-Edge \
--vm-name vm-Edge \
--name customScript \
--publisher Microsoft.Azure.Extensions \
--settings '{"fileUris":["https://raw.githubusercontent.com/dkirby-ms/MiscARM/refs/heads/main/installk3s.sh"], "commandToExecute":"sh installk3s.sh rg-edge '$objectId'"}'