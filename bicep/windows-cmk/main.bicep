// =============================================================================
// Windows VM with Encryption at Host + Customer-Managed Keys (CMK)
//
// Advanced lab exercise — demonstrates the target end-state after migrating
// from ADE to EaH, with a Disk Encryption Set (DES) backed by a
// customer-managed key in Key Vault.
//
// Deploys:
//   • Key Vault (purge-protection enabled, as required by DES)
//   • Key Vault Key for the Disk Encryption Set (CMK)
//   • Disk Encryption Set with auto-key-rotation
//   • Key Vault access policy for the DES managed identity
//   • Virtual Network + Subnet + NSG
//   • Public IP + NIC
//   • Windows Server 2022 VM with Encryption at Host + DES
//
// No ADE extension is deployed — this template represents the post-migration
// state with full customer key ownership.
// =============================================================================

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Prefix applied to every resource name.')
@minLength(2)
@maxLength(10)
param prefix string = 'cmklab'

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

@description('Object ID of the user / service-principal that will manage Key Vault secrets and keys.')
param keyVaultAdminObjectId string

@description('Allowed source IP for RDP (port 3389). Use your public IP or a CIDR. Defaults to deny-all.')
param allowedRdpSourceAddress string = 'Deny'

@description('Virtual network address space CIDR.')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Subnet address prefix CIDR.')
param subnetAddressPrefix string = '10.0.0.0/24'

@description('DO NOT SUPPLY — auto-generated timestamp that ensures a unique Key Vault name per deployment, avoiding soft-delete conflicts on redeployment.')
param deploymentTimestamp string = utcNow('yyyyMMddHHmmss')

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

var kvName = '${prefix}-kv-${take(uniqueString(resourceGroup().id, deploymentTimestamp), 24 - length(prefix) - 4)}'
var vnetName = '${prefix}-vnet'
var subnetName = 'default'
var nsgName = '${prefix}-nsg'
var publicIpName = '${prefix}-pip'
var nicName = '${prefix}-nic'
var vmName = '${prefix}-win-vm'
var desKeyName = '${prefix}-des-key'
var desName = '${prefix}-des'

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
            'create'
            'delete'
            'get'
            'list'
            'wrapKey'
            'unwrapKey'
          ]
          secrets: [
            'get'
            'list'
            'set'
          ]
        }
      }
    ]
  }
}

resource desKey 'Microsoft.KeyVault/vaults/keys@2023-07-01' = {
  parent: keyVault
  name: desKeyName
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
// Disk Encryption Set
// ---------------------------------------------------------------------------

resource diskEncryptionSet 'Microsoft.Compute/diskEncryptionSets@2023-10-02' = {
  name: desName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    activeKey: {
      keyUrl: desKey.properties.keyUriWithVersion
      sourceVault: {
        id: keyVault.id
      }
    }
    encryptionType: 'EncryptionAtRestWithCustomerKey'
    rotationToLatestKeyVersionEnabled: true
  }
}

// Grant the DES managed identity access to the Key Vault key
resource desAccessPolicy 'Microsoft.KeyVault/vaults/accessPolicies@2023-07-01' = {
  parent: keyVault
  name: 'add'
  properties: {
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: diskEncryptionSet.identity.principalId
        permissions: {
          keys: [
            'get'
            'wrapKey'
            'unwrapKey'
          ]
        }
      }
    ]
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
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetAddressPrefix
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
// Virtual Machine — Encryption at Host + CMK via Disk Encryption Set
// ---------------------------------------------------------------------------

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  dependsOn: [
    desAccessPolicy
  ]
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
          diskEncryptionSet: {
            id: diskEncryptionSet.id
          }
        }
        deleteOption: 'Delete'
      }
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
      encryptionAtHost: true
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
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

@description('Name of the OS managed disk.')
output osDiskName string = vm.properties.storageProfile.osDisk.name

@description('Resource ID of the OS managed disk.')
output osDiskId string = vm.properties.storageProfile.osDisk.managedDisk.id

@description('Resource ID of the network interface.')
output nicId string = nic.id

@description('Resource ID of the subnet.')
output subnetId string = '${vnet.id}/subnets/${subnetName}'

@description('VM size SKU.')
output vmSize string = vm.properties.hardwareProfile.vmSize

@description('Resource ID of the Disk Encryption Set.')
output diskEncryptionSetId string = diskEncryptionSet.id

@description('Name of the Disk Encryption Set.')
output diskEncryptionSetName string = diskEncryptionSet.name

@description('Versioned URI of the Customer-Managed Key used by the DES.')
output cmkKeyId string = desKey.properties.keyUriWithVersion
