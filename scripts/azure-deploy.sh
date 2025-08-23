#!/bin/bash

# Exit immediately if any command fails
set -e

##### This script sssumes you are already logged into Azure CLI with az login

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

# create resource group for k8s
echo "Creating resource group $RESOURCE_GROUP in $LOCATION..."
az group create --name $RESOURCE_GROUP --location $LOCATION

# register necessary providers to be able to use AKS
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

# create AKS cluster
# --enable-app-routing required for nginx ingress controller
# https://learn.microsoft.com/en-us/azure/aks/app-routing#enable-on-a-new-cluster
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
    --generate-ssh-keys \
    --kubernetes-version 1.33

# log into to kubectl for the cluster
echo "Getting AKS cluster credentials for kubectl..."
az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME

# create nginx ingress controller class
# https://learn.microsoft.com/en-us/azure/aks/app-routing-nginx-configuration?tabs=azurecli
echo "Creating NGINX Ingress Controller..."
kubectl apply -f nginx-public-controller.yaml

echo "Deploying eoapi to AKS cluster..."
make -C .. deploy

# get the ingress IP addresses
echo "Fetching Ingress IPs..."
kubectl get ingress -n eoapi
