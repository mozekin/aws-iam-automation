#Requires -Version 5

<#
.SYNOPSIS
	This script is for publishing the state of the local assets (roles, policies) to the relevant accounts in AWS.
.NOTES
	The pauses are mainly to limit the rate of API calls in order to avoid being throttled by AWS,
	but also provide the engineer the chance to easily see which account/role the process is up to.
.PARAMETER RootFolder
	The root folder containing your user assets.
.PARAMETER AccountFilter
	An optional filter used to limit the accounts that are published.
.PARAMETER RoleFilter
	An optional filter used to limit the roles that are published.
.PARAMETER Force
	An optional switch to suppress any confirmation prompts. Intended only for non-interactive scenarios.
.EXAMPLE
    ./Publish-State.ps1 -RootFolder ~/some-folder 
.EXAMPLE
    ./Publish-State.ps1 -RootFolder ~/some-folder -AccountFilter master -RoleFilter admin -Verbose
#>
param
(
    [Parameter(Mandatory=$true)]
    [string] 
    $RootFolder,

	[Parameter(Mandatory=$false)]
    [string] 
    $AccountFilter,

	[Parameter(Mandatory=$false)]
    [string] 
    $RoleFilter,

	[Parameter(Mandatory=$false)]
	[switch] 
	$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$SecondsToWaitBetweenCalls = 2
$AwsSessionTimeoutSeconds = 60*60
$SecondsToWaitForStackActions = 60
$GlobalTemplateFilename = "global.template"
$ConfigFilename = "config.json"
$RoleFilename = "role.template"
$PolicyFilename = "policy.json"
$DefaultRegion = "ap-southeast-2"


function IsDebug {
    [CmdletBinding()]
    param()
        $DebugPreference -ne [System.Management.Automation.ActionPreference]::SilentlyContinue
}
function IsVerbose {
    [CmdletBinding()]
    param()
        $VerbosePreference -ne [System.Management.Automation.ActionPreference]::SilentlyContinue
}

function LoadRequiredModules {
	Write-Verbose "Attempting to load the required modules..."
    Write-Verbose "   Checking the Powershell edition..."
    $hostIsPowershellCore = ($PSVersionTable.ContainsKey("PSEdition") -and ($PSVersionTable.PSEdition -eq "Core"))
    Write-Verbose "   hostIsPowershellCore : [$hostIsPowershellCore]"
	Write-Verbose (Get-Module -ListAvailable -Verbose:$false "AWS*" | Format-Table | Out-String)

	$requiredModuleName = "AWSPowerShell.NetCore"
    if ($hostIsPowershellCore) {
		if ((Get-Module -ListAvailable -Verbose:$false $requiredModuleName) -eq $null) {
			Install-Module $requiredModuleName -Verbose:$false
		}
		Write-Verbose "   Loading module : [$requiredModuleName]"
		Import-Module $requiredModuleName -Verbose:$false
	}

    $requiredModuleName = "AWSPowerShell"
    if (!$hostIsPowershellCore) {
		if (!$hostIsPowershellCore -and (Get-Module -ListAvailable -Verbose:$false $requiredModuleName) -eq $null) {
			Install-Module $requiredModuleName -Verbose:$false
		}
		Write-Verbose "   Loading module : [$requiredModuleName]"
		Import-Module $requiredModuleName -Verbose:$false
	}

	$powershellModulesPath = "$PSScriptRoot/powershell-modules"
	Write-Verbose "   Loading internal modules..."
	Write-Verbose "   powershellModulesPath : [$powershellModulesPath]"
	Import-Module "$powershellModulesPath/AWS-CloudFormation.psm1"
	Import-Module "$powershellModulesPath/AWS-IAM.psm1"
	Import-Module "$powershellModulesPath/JSON-Utils.psm1"
}




function GetAccountFolders {
	Write-Verbose "Attempting to get account folders..."
	Write-Verbose "   RootFolder : [$RootFolder]"
	Write-Verbose "   AccountFilter : [$AccountFilter]"
	if ([string]::IsNullOrEmpty($AccountFilter)) {
		$accountFolders = Get-ChildItem $RootFolder -Directory
	} else {
		$accountFolders = Get-ChildItem -Path $RootFolder -Directory | Where-Object { $_.Name.Contains($AccountFilter) } | Sort-Object
	}
	Write-Verbose "$accountFolders"
	return $accountFolders
}

function GetRoleFolders($accountFolder) {
	Write-Verbose "Attempting to get role folders..."
	Write-Verbose "   accountFolder : [$accountFolder]"
	Write-Verbose "   RoleFilter : [$RoleFilter]"
	if ([string]::IsNullOrEmpty($RoleFilter)) {
		$roleFolders = Get-ChildItem $accountFolder -Directory 
	} else {
		$roleFolders = Get-ChildItem -Path $accountFolder -Directory | Where-Object { $_.Name.Contains($RoleFilter) } | Sort-Object
	}
	return $roleFolders
}

function ValidateRootFolder {
	Write-Host "Validating root folder..."
	Write-Verbose "   RootFolder : [$RootFolder]"
	if (!(Test-Path -Path $RootFolder)) {
		throw "The given RootFolder does not exist : $RootFolder"
	}
	$accountFolders = GetAccountFolders
	if (!$accountFolders) {
		throw "The given root folder contains no account folders : $RootFolder"		
	}
	Write-Host "   Root folder passed validation"
}

function ValidateAccountFolder($accountFolder) {
	Write-Host "Validating account folder..."
	Write-Verbose "   accountFolder : [$accountFolder]"
	if (!(Test-Path -Path $accountFolder)) {
		throw "The given account folder does not exist : $accountFolder"
	}
	$configFilePath = "$accountFolder/$ConfigFilename"
	if (!(Test-Path -Path $configFilePath)) {
		throw "The given account folder is missing a config file : $configFilePath"
	}	
	$roleFolders = GetRoleFolders $accountFolder
	if (!$roleFolders -and [string]::IsNullOrEmpty($RoleFilter)) {
		throw "The given account folder contains no role folders : $accountFolder"	
	} 
	if (!$roleFolders) {
		Write-Warning "   No role folders were found for the given filter!"		
		return
	} 
	Write-Host "   Account folder passed validation"
}

function ValidateRoleFolder($roleFolder) {
	Write-Host "Validating role folder..."
	Write-Verbose "   roleFolder : [$roleFolder]"
	$roleFilePath = "$roleFolder/$RoleFilename"
	if (!(Test-Path -Path $roleFilePath)) {
		throw "The given role folder is missing a role file : $roleFilePath"
	}
	$policyFilePath = "$roleFolder/$PolicyFilename"
	if (!(Test-Path -Path $policyFilePath)) {
		throw "The given role folder is missing a policy file : $policyFilePath"
	}
	Write-Host "   Role folder passed validation"
}


function ValidateConfigJson($accountFolder) {
	$configFilePath = "$accountFolder/$ConfigFilename"
	$configJson = Get-JsonObject $configFilePath
	Write-Host "Attempting to validate config JSON..."
	Write-Verbose "   accountFolder : [$accountFolder]"
	Write-Verbose "   configFilePath : [$configFilePath]"
	Write-Verbose "   Validating properties on config JSON..."
	Assert-PropertiesExist -Json $configJson -Properties @("AccountName", "AccountNumber", "Region", "EnactingRoleArn")
	Write-Host "   Successfully validated config JSON"
	return $configJson
}

function ValidateRoleJson($roleFolder) {
	$roleFilePath = "$roleFolder/$RoleFilename"
	$roleJson = Get-JsonObject $roleFilePath
	$globalTemplateFilepath = "$RootFolder/$GlobalTemplateFilename"
	$globalTemplateJson = Get-JsonObject $globalTemplateFilepath
	Write-Host "Attempting to validate role JSON..."
	Write-Verbose "   roleFolder : [$roleFolder]"
	Write-Verbose "   roleFilePath : [$roleFilePath]"
	Write-Verbose "   globalTemplateFilepath : [$globalTemplateFilepath]"
	Write-Verbose "   Validating properties on role JSON..."
	Assert-PropertiesExist -Json $roleJson -Properties @("AWSTemplateFormatVersion", "Description", "Resources")
	Write-Verbose "   Validating properties on global JSON..."
	Assert-PropertiesExist -Json $globalTemplateJson -Properties @("Parameters", "Mappings", "Conditions")
	Write-Verbose "   Attempting to merge global template into role template..."
	$roleJson = Merge-Json -SourceJson $globalTemplateJson -TargetJson $roleJson	
	Write-Host "   Successfully validated role JSON"
	return ConvertTo-JsonDeep -JsonObject $roleJson
}

function ValidatePolicyJson($roleFolder) {
	$policyFilePath = "$roleFolder/$PolicyFilename"
	$policyJson = Get-JsonObject $policyFilePath
	Write-Host "Attempting to validate policy JSON..."
	Write-Verbose "   roleFolder : [$roleFolder]"
	Write-Verbose "   policyFilePath : [$policyFilePath]"
	Write-Verbose "   Validating properties on policy JSON..."
	Assert-PropertiesExist -Json $policyJson -Properties @("Version", "Statement")	
	Write-Host "   Successfully validated policy JSON"
	return ConvertTo-JsonDeep -JsonObject $policyJson
}


function UpsertRole($accountNumber, $region, $roleFolder, $roleName, $roleJson) {
	$stackName = $roleName # stack, role and policy names are the same for consistency
	Write-Host "Attempting to upsert role..."
	Write-Verbose "   roleName : [$roleName]"
	Write-Verbose "   stackName : [$stackName]"
	Write-Verbose "   Checking if stack exists..."
	$existingStack = Get-Stack -StackName $stackName -Region $region -Verbose:$(IsVerbose)
	Write-Verbose "   response : [$existingStack]"
	Write-Verbose "   Checking if role exists..."
	$existingRole = Get-Role -RoleName $roleName -Verbose:$(IsVerbose)
	Write-Verbose "   response : [$existingRole]"

	# if the role was created manually outside CF then we want it gone
	if (!$existingStack -and $existingRole) {
		Write-Verbose "   Role exists without a stack - attempting to delete..."
		Remove-Role -RoleName $roleName -Region $region -Force:$Force -Verbose:$(IsVerbose)
	}
	Publish-Stack -StackName $stackName -TemplateBody $roleJson -Region $region -MaxSecondsToWait 300 -Verbose:$(IsVerbose)
}










LoadRequiredModules
Clear-EnvironmentCreds
Write-Host
Write-Host "################################################################################################"
Write-Host "##"
Write-Host "##  AWS IAM State Publisher"
Write-Host "##  - Used to publish IAM roles/policies to AWS accounts."
Write-Host "##"
Write-Host "##  Listing current parameters..."
Write-Host "##     RootFolder"
Write-Host "##        [$RootFolder]"
Write-Host "##     AccountFilter"
Write-Host "##        [$AccountFilter]"
Write-Host "##     RoleFilter"
Write-Host "##        [$RoleFilter]"
Write-Host "##     SecondsToWaitBetweenCalls"
Write-Host "##        [$SecondsToWaitBetweenCalls]"
Write-Host "##     SecondsToWaitForStackActions"
Write-Host "##        [$SecondsToWaitForStackActions]"
Write-Host "##     AwsSessionTimeoutSeconds"
Write-Host "##        [$AwsSessionTimeoutSeconds]"
Write-Host "##     DefaultRegion"
Write-Host "##        [$DefaultRegion]"
Write-Host "##     Force"
Write-Host "##        [$Force]"
Write-Host "##"
Write-Host "################################################################################################"
Write-Host
Write-Host "Attempting to get current AWS identity..."
Write-Host ((Get-CurrentIamIdentity -Region $DefaultRegion) | Format-Table | Out-String)
Write-Host
if (!$Force) {
	$userPromptResponse = Read-Host -Prompt "Do you want to proceed with these params? ('Yes' to proceed)"
	if ($userPromptResponse -ne "Yes") {
		Write-Host "You have cancelled - nothing has happened."
		exit 0
	}
}

ValidateRootFolder
$accountFolders = GetAccountFolders

foreach ($accountFolder in $accountFolders) {
	$accountFolderFull = $accountFolder.Fullname
	$accountFolderName = $accountFolder.Name
	Write-Host
	Write-Host "---------------------------------------------------------------------------------------------"
	Write-Host "   Account: $accountFolderName "
	Write-Host "---------------------------------------------------------------------------------------------"
	Start-Sleep $SecondsToWaitBetweenCalls

	ValidateAccountFolder $accountFolderFull

	$configJson = ValidateConfigJson $accountFolderFull
	$accountNumber = $configJson.AccountNumber
	$region = $configJson.Region
	$enactingRoleArn = $configJson.EnactingRoleArn
	$enactingRoleSessionName = "$accountNumber-enactor"

	Switch-Role -RoleArn $enactingRoleArn -RoleSessionName $enactingRoleSessionName -Region $region -Verbose:$(IsVerbose)
	Write-Host "Attempting to get current AWS identity (should be the enacting role)..."
	Write-Host ((Get-CurrentIamIdentity -Region $DefaultRegion) | Format-Table | Out-String)

	$roleFolders = GetRoleFolders $accountFolderFull
	foreach($roleFolder in $roleFolders) {
		$roleFolderFull = $roleFolder.Fullname
		$roleFolderName = $roleFolder.Name
		Write-Host
		Write-Host "---------------------------------------------------------------------------------------------"
		Write-Host "   Account: $accountFolderName    Role: $roleFolderName"
		Write-Host "---------------------------------------------------------------------------------------------"
		Start-Sleep $SecondsToWaitBetweenCalls

		ValidateRoleFolder $roleFolderFull
		$policyJson = ValidatePolicyJson $roleFolderFull
		$roleJson = ValidateRoleJson $roleFolderFull

		Publish-Policy -AccountNumber $accountNumber -PolicyName $roleFolderName -PolicyDocumentBody $policyJson -Force:$Force -Verbose:$(IsVerbose)
		UpsertRole $accountNumber $region $roleFolderFull $roleFolderName $roleJson

	}
}

Write-Host
Write-Host
Write-Host "Publishing completed!"
Write-Host


