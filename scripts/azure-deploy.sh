#!/bin/bash

# Exit immediately if any command fails
set -e

##### This script assumes you are already logged into Azure CLI with az login

# Steps
# 1. Create resource group
# 2. Register necessary providers
# 3. Create AKS cluster
# 4. Get AKS credentials for kubectl
# 5. Create managed identity for workload identity
# 6. Create Kubernetes service accounts for workload identity
# 7. Create federated identity credential to establish trust between K8s SA and Azure identity
# 8. Grant storage access to the managed identity
# 9. Create nginx ingress controller class
# 10. Install cert-manager for SSL certificates
# 11. Create Let's Encrypt ClusterIssuer to issue SSL certificates
# 12. Deploy eoapi to AKS cluster
# 13. Get the ingress IP addresses
# 14. (MANUAL) Update DNS records for eoapi.tealwaters.com to point to the ingress IPs

# Set default values
RESOURCE_GROUP="eoapi-rg"
LOCATION="eastus"
CLUSTER_NAME="eoapi-aks"

# Parse named arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -g|--resource-group)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        -l|--location)
            LOCATION="$2"
            shift 2
            ;;
        -n|--cluster-name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  -g, --resource-group <name>   Resource group name (default: eoapi-rg)"
            echo "  -l, --location <location>     Azure region (default: eastus)"
            echo "  -n, --cluster-name <name>     AKS cluster name (default: eoapi-aks)"
            echo "  -h, --help                    Show this help message"
            echo ""
            echo "Example: $0 --resource-group my-rg --location westus --cluster-name my-cluster"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

echo "Creating AKS cluster with the following parameters:"
echo "Resource Group: $RESOURCE_GROUP"
echo "Location: $LOCATION"
echo "Cluster Name: $CLUSTER_NAME"
echo ""

# 1. create resource group for k8s
echo "Creating resource group $RESOURCE_GROUP in $LOCATION..."
az group create --name $RESOURCE_GROUP --location $LOCATION

# 2. register necessary providers to be able to use AKS
echo "Registering necessary Azure providers..."
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.Compute
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.Storage
az provider register --namespace Microsoft.Authorization
az provider register --namespace Microsoft.KeyVault
az provider register --namespace Microsoft.ManagedIdentity
az provider register --namespace Microsoft.OperationalInsights
az provider register --namespace Microsoft.Insights

# 3. create AKS cluster
# --enable-app-routing required for nginx ingress controller
# https://learn.microsoft.com/en-us/azure/aks/app-routing#enable-on-a-new-cluster
# --enable-workload-identity and --enable-oidc-issuer required for workload identity
echo "Creating AKS cluster $CLUSTER_NAME..."
az aks create \
    --resource-group $RESOURCE_GROUP \
    --tier free \
    --name $CLUSTER_NAME \
    --enable-cluster-autoscaler \
    --node-count 1 \
    --min-count 1 \
    --max-count 10 \
    --node-vm-size Standard_B4ms \
    --enable-addons monitoring \
    --enable-app-routing \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --generate-ssh-keys \
    --kubernetes-version 1.33

# 4. log into to kubectl for the cluster
echo "Getting AKS cluster credentials for kubectl..."
az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME

# 5. create managed identity for workload identity
echo "Creating managed identity for workload identity..."
az identity create --resource-group $RESOURCE_GROUP --name eoapi-workload-identity --location $LOCATION

# 6. create Kubernetes service accounts for workload identity
echo "Creating Kubernetes service accounts for workload identity..."
IDENTITY_CLIENT_ID=$(az identity show --resource-group $RESOURCE_GROUP --name eoapi-workload-identity --query "clientId" -o tsv)
cat > workload-identity-setup.yaml << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: "${IDENTITY_CLIENT_ID}"
  name: eoapi-workload-identity
  namespace: default
EOF
kubectl apply -f workload-identity-setup.yaml

# 7. create federated identity credential to establish trust between K8s SA and Azure identity
echo "Creating federated identity credential..."
OIDC_ISSUER=$(az aks show --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --query "oidcIssuerProfile.issuerUrl" -o tsv)
az identity federated-credential create \
    --name eoapi-federated-identity \
    --identity-name eoapi-workload-identity \
    --resource-group $RESOURCE_GROUP \
    --issuer $OIDC_ISSUER \
    --subject system:serviceaccount:eoapi:eoapi-workload-identity

# 8. grant storage access to the managed identity
echo "Granting Storage Blob Data Contributor role to managed identity..."
SUBSCRIPTION_ID=$(az account show --query "id" -o tsv)
az role assignment create \
    --assignee $IDENTITY_CLIENT_ID \
    --role "Storage Blob Data Contributor" \
    --scope "/subscriptions/$SUBSCRIPTION_ID"

# 9. create nginx ingress controller class
# https://learn.microsoft.com/en-us/azure/aks/app-routing-nginx-configuration?tabs=azurecli
echo "Creating NGINX Ingress Controller..."
kubectl apply -f nginx-public-controller.yaml

# 10. install cert-manager for SSL certificates
echo "Installing cert-manager..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.18.2/cert-manager.yaml

# wait for cert-manager to be ready
echo "Waiting for cert-manager to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager -n cert-manager
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-webhook -n cert-manager
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-cainjector -n cert-manager

# 11. create Let's Encrypt ClusterIssuer
echo "Creating Let's Encrypt ClusterIssuer to issue SSL certificates..."
kubectl apply -f letsencrypt-issuer.yaml

# 12. deploy eoapi to AKS cluster
echo "Deploying eoapi to AKS cluster..."
./scripts/deployment.sh run

# 13. get the ingress IP addresses
echo "Fetching Ingress IPs..."
kubectl get ingress -n eoapi
