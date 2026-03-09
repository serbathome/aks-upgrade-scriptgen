# Project Documentation

## Technical Stack
- **Operating System:** Linux
- **Script Language:** Bash (Shell Script)
- **Main File:** create-upgrade-scripts.sh

## Business Logic
This project automates the generation of upgrade scripts for Azure Kubernetes Service (AKS) environments. The main script (`create-upgrade-scripts.sh`) is designed to streamline the upgrade process by:
- Identifying AKS clusters that require upgrades.
- Generating upgrade scripts tailored to each cluster's configuration.
- Ensuring minimal downtime and operational consistency during upgrades.

The script leverages Azure CLI commands and Bash scripting to interact with AKS resources, extract relevant information, and produce upgrade scripts that can be executed to update clusters efficiently.

## Usage
Run the `create-upgrade-scripts.sh` script in a Linux environment with Azure CLI installed and authenticated. The script will output upgrade scripts for each AKS cluster found in the target subscription or resource group.

## Extensibility
The project can be extended to support additional cloud providers or more complex upgrade scenarios by modifying the main script or adding new modules.
