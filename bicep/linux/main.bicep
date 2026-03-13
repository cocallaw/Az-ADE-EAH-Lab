// =============================================================================
// Linux VM with Azure Disk Encryption (ADE) – Lab Starting Point
//
// Deploys:
//   • Key Vault (disk-encryption enabled)
//   • Key Vault Key for ADE
//   • Virtual Network + Subnet + NSG
//   • Public IP + NIC
//   • Ubuntu 22.04 LTS VM
//   • ADE VM extension (Microsoft.Azure.Security.AzureDiskEncryptionForLinux)
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
@maxLength(64)
param adminUsername string

@description('SSH public key for the VM admin account.')
param adminSshPublicKey string

@description('Linux VM SKU size.')
param vmSize string = 'Standard_D2s_v5'

@description('Object ID of the user / service-principal that will manage Key Vault secrets.')
param keyVaultAdminObjectId string

@description('Allowed source IP for SSH (port 22). Use your public IP or a CIDR. Defaults to deny-all.')
param allowedSshSourceAddress string = 'Deny'

@description('Unique value passed to forceUpdateTag on the ADE extension. Change this to force re-encryption (e.g. pass a new GUID).')
param sequenceVersion string = '1.0'

@description('Virtual network address space CIDR.')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Subnet address prefix CIDR.')
param subnetAddressPrefix string = '10.0.0.0/24'

@description('DO NOT SUPPLY — auto-generated timestamp that ensures a unique Key Vault name per deployment, avoiding soft-delete conflicts on redeployment.')
param deploymentTimestamp string = utcNow('yyyyMMddHHmmss')

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

var kvName = '${prefix}-kv-${uniqueString(resourceGroup().id, deploymentTimestamp)}'
var vnetName = '${prefix}-vnet'
var subnetName = 'default'
var nsgName = '${prefix}-nsg'
var publicIpName = '${prefix}-pip'
var nicName = '${prefix}-nic'
var vmName = '${prefix}-lnx-vm'
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
        name: 'Allow-SSH'
        properties: {
          priority: 1000
          protocol: 'Tcp'
          access: allowedSshSourceAddress == 'Deny' ? 'Deny' : 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: allowedSshSourceAddress == 'Deny' ? '*' : allowedSshSourceAddress
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
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
// Virtual Machine
// ---------------------------------------------------------------------------

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
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

resource adeExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'AzureDiskEncryptionForLinux'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Security'
    type: 'AzureDiskEncryptionForLinux'
    typeHandlerVersion: '1.1'
    autoUpgradeMinorVersion: true
    forceUpdateTag: sequenceVersion
    settings: {
      EncryptionOperation: 'EnableEncryption'
      KeyVaultURL: keyVault.properties.vaultUri
      KeyVaultResourceId: keyVault.id
      KeyEncryptionKeyURL: adeKey.properties.keyUriWithVersion
      KekVaultResourceId: keyVault.id
      KeyEncryptionAlgorithm: 'RSA-OAEP'
      // 'All' encrypts all volumes. OS-disk encryption on Linux requires
      // swap to be disabled before enabling ADE.
      VolumeType: 'All'
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
