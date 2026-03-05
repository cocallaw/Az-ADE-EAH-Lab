// =============================================================================
// Windows VM with Azure Disk Encryption (ADE) – Lab Starting Point
//
// Deploys:
//   • Resource Group (optional – created outside this template)
//   • Key Vault (disk-encryption enabled, RBAC or access-policy)
//   • Key Vault Key for ADE
//   • Virtual Network + Subnet + NSG
//   • Public IP + NIC
//   • Windows Server 2022 VM
//   • ADE VM extension (Microsoft.Azure.Security.AzureDiskEncryption)
//
// After deployment run the migration scripts in /scripts/ to move to EaH.
// =============================================================================

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Prefix applied to every resource name.')
@minLength(2)
@maxLength(10)
param prefix string = 'adelab'

@description('Admin username for the VM.')
@minLength(1)
@maxLength(20)
param adminUsername string

@description('Admin password for the VM.')
@secure()
@minLength(12)
param adminPassword string

@description('Windows VM SKU size.')
param vmSize string = 'Standard_D2s_v5'

@description('Object ID of the user / service-principal that will manage Key Vault secrets.')
param keyVaultAdminObjectId string

@description('Allowed source IP for RDP (port 3389). Use your public IP or a CIDR. Defaults to deny-all.')
param allowedRdpSourceAddress string = 'Deny'

@description('Unique value passed to forceUpdateTag on the ADE extension. Change this to force re-encryption (e.g. pass a new GUID).')
param sequenceVersion string = '1.0'

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

var kvName = '${prefix}-kv-${uniqueString(resourceGroup().id)}'
var vnetName = '${prefix}-vnet'
var subnetName = 'default'
var nsgName = '${prefix}-nsg'
var publicIpName = '${prefix}-pip'
var nicName = '${prefix}-nic'
var vmName = '${prefix}-win-vm'
var keyName = '${prefix}-ade-key'
// ---------------------------------------------------------------------------
// Key Vault
// ---------------------------------------------------------------------------

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enabledForDiskEncryption: true
    enabledForDeployment: true
    enabledForTemplateDeployment: true
    enableRbacAuthorization: false
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: keyVaultAdminObjectId
        permissions: {
          keys: [
            'all'
          ]
          secrets: [
            'all'
          ]
          certificates: [
            'all'
          ]
        }
      }
    ]
  }
}

resource adeKey 'Microsoft.KeyVault/vaults/keys@2023-07-01' = {
  parent: keyVault
  name: keyName
  properties: {
    kty: 'RSA'
    keySize: 3072
    keyOps: [
      'encrypt'
      'decrypt'
      'sign'
      'verify'
      'wrapKey'
      'unwrapKey'
    ]
    attributes: {
      enabled: true
    }
  }
}

// ---------------------------------------------------------------------------
// Networking
// ---------------------------------------------------------------------------

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-RDP'
        properties: {
          priority: 1000
          protocol: 'Tcp'
          access: allowedRdpSourceAddress == 'Deny' ? 'Deny' : 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: allowedRdpSourceAddress == 'Deny' ? '*' : allowedRdpSourceAddress
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.0.0.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: '${vnet.id}/subnets/${subnetName}'
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Virtual Machine
// ---------------------------------------------------------------------------

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        patchSettings: {
          patchMode: 'AutomaticByOS'
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        deleteOption: 'Delete'
      }
      dataDisks: [
        {
          lun: 0
          name: '${vmName}-datadisk0'
          createOption: 'Empty'
          diskSizeGB: 32
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
          deleteOption: 'Delete'
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    securityProfile: {
      // encryptionAtHost is intentionally NOT set here – this is the ADE starting state
      encryptionAtHost: false
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Azure Disk Encryption VM Extension
// ---------------------------------------------------------------------------

resource adeExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: vm
  name: 'AzureDiskEncryption'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Security'
    type: 'AzureDiskEncryption'
    typeHandlerVersion: '2.2'
    autoUpgradeMinorVersion: true
    forceUpdateTag: sequenceVersion
    settings: {
      EncryptionOperation: 'EnableEncryption'
      KeyVaultURL: keyVault.properties.vaultUri
      KeyVaultResourceId: keyVault.id
      KeyEncryptionKeyURL: adeKey.properties.keyUriWithVersion
      KekVaultResourceId: keyVault.id
      KeyEncryptionAlgorithm: 'RSA-OAEP'
      VolumeType: 'All'
      ResizeOSDisk: false
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Resource ID of the deployed VM.')
output vmId string = vm.id

@description('Name of the VM.')
output vmName string = vm.name

@description('Resource ID of the Key Vault.')
output keyVaultId string = keyVault.id

@description('URI of the Key Vault.')
output keyVaultUri string = keyVault.properties.vaultUri

@description('Name of the Key Vault.')
output keyVaultName string = keyVault.name

@description('Public IP address of the VM.')
output publicIpAddress string = publicIp.properties.ipAddress

@description('Resource Group name.')
output resourceGroupName string = resourceGroup().name
