#Requires -Version 5
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module "$PSScriptRoot/JSON-Utils.psm1"


function Get-CurrentIamIdentity {
	<#
	.SYNOPSIS
		Attempts to fetch your current active identity for the given region, or throws an error.
	.PARAMETER Region
		The region to check against.
	.OUTPUTS
		Returns the [Amazon.SecurityToken.Model.GetCallerIdentityResponse] object if a valid identity exists.
	.EXAMPLE
		$myIdentity = Get-CurrentIamIdentity -Region ap-southeast-2
	#>
	param
	(
		[Parameter(Mandatory=$true)]
		[string] 
		$Region
	)
	Write-Verbose "Attempting to determine the current identity..."
	Write-Verbose "   Region : [$Region]"
	$currentIamIdentity = Get-STSCallerIdentity -Region $Region
	if ($currentIamIdentity -eq $null) {
		throw "You don't have any current AWS IAM identity (do you need to refresh your session creds?)"
	}
	return $currentIamIdentity
}
Export-ModuleMember -function Get-CurrentIamIdentity



function Clear-EnvironmentCreds {
	<#
	.SYNOPSIS
		Clears the AWS environment values.
	.EXAMPLE
		Clear-EnvironmentCreds
	#>
	Write-Verbose "Attemping to clear environment credentials..."
    $env:AWS_ACCESS_KEY_ID = $null
    $env:AWS_SECRET_ACCESS_KEY = $null
    $env:AWS_SESSION_TOKEN = $null
    $env:AWS_SESSION_EXPIRATION = $null
    $env:AWS_CURRENT_ROLE = $null
}
Export-ModuleMember -function Clear-EnvironmentCreds




function Switch-Role {
	<#
	.SYNOPSIS
		Attempts to assume the given IAM role.
	.PARAMETER RoleArn
		The ARN of the role to assume.
	.PARAMETER RoleSessionName
		The name you wish to apply to the assume-role session.
	.PARAMETER Region
		The region to use.
	.PARAMETER SessionDurationSeconds
		The optional number of seconds for the session to remain valid (default is 1 hour).
	.EXAMPLE
		Switch-Role -RoleArn arn:aws:iam::1234567890:role/foo-role -RoleSessionName foo-session -Region ap-southeast-2
	#>
	param
	(
		[Parameter(Mandatory=$true)]
		[string] 
		$RoleArn,

		[Parameter(Mandatory=$true)]
		[string] 
		$RoleSessionName,

		[Parameter(Mandatory=$true)]
		[string] 
		$Region,

		[Parameter(Mandatory=$false)]
		[int] 
		$SessionDurationSeconds = 60 * 60
	)	
    Write-Verbose "Attempting to switch role..."
    Write-Verbose "   RoleARN : [$RoleArn]"
    Write-Verbose "   RoleSessionName : [$RoleSessionName]"
    Write-Verbose "   Region : [$Region]"
    Write-Verbose "   SessionDurationSeconds : [$SessionDurationSeconds]"
	Clear-EnvironmentCreds
	Write-Verbose ((Get-CurrentIamIdentity -Region $Region) | Format-Table | Out-String)
    Write-Verbose "   Using STS role..."
    $assumeRoleResponse = Use-STSRole -RoleArn $RoleArn -RoleSessionName $RoleSessionName -DurationInSeconds $SessionDurationSeconds -Region $Region
    if ($assumeRoleResponse -eq $null) {
        throw "Failed to switch role, your current creds may not have access, or the role may not allow switching to other roles"
    }
    Write-Verbose "   Role switched, persisting creds in env..."
    $tempCreds = $assumeRoleResponse.Credentials
    $env:AWS_ACCESS_KEY_ID = $tempCreds.AccessKeyId
    $env:AWS_SECRET_ACCESS_KEY = $tempCreds.SecretAccessKey
    $env:AWS_SESSION_TOKEN = $tempCreds.SessionToken
    $env:AWS_SESSION_EXPIRATION = $tempCreds.Expiration
    $env:AWS_CURRENT_ROLE = $RoleArn
    Write-Verbose "   Switch role action was successful"
}
Export-ModuleMember -function Switch-Role




function Get-Role {
	<#
	.SYNOPSIS
		Attempts to find an IAM role with the given name in the given region.
	.PARAMETER RoleName
		The name of the role to match with.
	.OUTPUTS
		Returns the matched [Amazon.IdentityManagement.Model.Role] object, else null.
	.EXAMPLE
		$myRole = Get-Role -RoleName foo-role -Region ap-southeast-2
	#>
	param
	(
		[Parameter(Mandatory=$true)]
		[string] 
		$RoleName
	)	
	try {
		Write-Verbose "Attempting to find IAM role..."
		Write-Verbose "   RoleName : [$RoleName]"
		return Get-IAMRole -RoleName $RoleName 
	} catch [System.InvalidOperationException] {
		return $null		
	} catch {
		Write-Error "Error finding IAM role by name : $RoleName"
		throw
	}
}
Export-ModuleMember -function Get-Role





function Get-Policy {
	<#
	.SYNOPSIS
		Attempts to find an IAM managed policy with the given name in the given account.
	.PARAMETER AccountNumber
		The name of the stack to match with.
	.PARAMETER PolicyName
		The region to search in.
	.OUTPUTS
		Returns the matched [Amazon.IdentityManagement.Model.ManagedPolicy] object, else null.
	.EXAMPLE
		$myPolicy = Get-Policy -AccountNumber 1234567890 -PolicyName foo-policy
	#>
	param
	(
		[Parameter(Mandatory=$true)]
		[string] 
		$AccountNumber,

		[Parameter(Mandatory=$true)]
		[string] 
		$PolicyName
	)	
    try {
		$policyArn = "arn:aws:iam::$AccountNumber`:policy/$PolicyName"
		Write-Verbose "Attempting to find IAM policy..."
		Write-Verbose "   AccountNumber : [$AccountNumber]"
		Write-Verbose "   PolicyName : [$PolicyName]"
		Write-Verbose "   policyArn : [$policyArn]"
        return Get-IAMPolicy -PolicyArn $policyArn
	} catch [System.InvalidOperationException] {
		return $null		
	} catch {
		Write-Error "Error finding IAM policy by name : $PolicyName"
		throw
	}
}
Export-ModuleMember -function Get-Policy



function Publish-Policy {
	<#
	.SYNOPSIS
		Upserts an IAM managed policy. If the policy exists updates it, otherwise creates it.
	.Notes
		When updating a policy, a new version is created and set as default, retaining the previous version.
	.PARAMETER AccountNumber
		The account number, used to construct the policy ARN.
	.PARAMETER PolicyName
		The name of the policy.
	.PARAMETER PolicyDocumentBody
		The IAM policy document body, as JSON formatted string.
	.PARAMETER Force
		Optional flag that when provided will suppress confirmations.
	.EXAMPLE
		Publish-Policy -AccountNumber 1234567890 -PolicyName foo-policy -PolicyDocumentFilename foo-policy.json
	#>
	param
	(
		[Parameter(Mandatory=$true)]
		[string] 
		$AccountNumber,

		[Parameter(Mandatory=$true)]
		[string] 
		$PolicyName,

		[Parameter(Mandatory=$true)]
		[string] 
		$PolicyDocumentBody,

		[Parameter(Mandatory=$false)]
		[switch] 
		$Force
	)	
	Write-Verbose "Attempting to publish managed policy..."
	Write-Verbose "   AccountNumber : [$AccountNumber]"
	Write-Verbose "   PolicyName : [$PolicyName]"
	Write-Verbose "   PolicyDocumentBody : [$PolicyDocumentBody]"
	Write-Verbose "   Force : [$Force]"
	Write-Verbose "   Attempting to load policy document..."
	Write-Verbose "   Checking if policy exists..."
	$existingPolicy = Get-Policy -AccountNumber $AccountNumber -PolicyName $PolicyName
    if ($existingPolicy) {
		$policyArn = $existingPolicy.arn
        Write-Verbose "   Policy exists - attempting to update it..."
		Write-Verbose "   policyArn : [$policyArn]"
        $currentDefaultVersionId = (Get-IAMPolicyVersionList -PolicyArn $policyArn | Where-Object { $_.IsDefaultVersion -eq $true }).VersionId
        Write-Verbose "   currentDefaultVersionId : [$currentDefaultVersionId]"
        New-IAMPolicyVersion -PolicyArn $policyArn -PolicyDocument $PolicyDocumentBody -SetAsDefault $true 
        $policyVersionsToDelete = Get-IAMPolicyVersionList -PolicyArn $policyArn | Where-Object { $_.IsDefaultVersion -eq $false -and $_.VersionId -ne $currentDefaultVersionId }
        foreach($policyVersion in $policyVersionsToDelete) {
            $policyVersionId = $policyVersion.VersionId
            Write-Verbose "   Attempting to remove unused policy version..."
			Write-Verbose "   policyVersionId : [$policyVersionId]"
			Remove-IAMPolicyVersion -PolicyArn $policyArn -VersionId $policyVersionId -Force:$Force
        }
        Write-Verbose "   Successfully updated existing managed policy"
    } else {
		Write-Verbose "   Policy doesn't exist - attempting to create it..."
        New-IAMPolicy -PolicyName $PolicyName -PolicyDocument $PolicyDocumentBody
        Write-Verbose "   Successfully created new managed policy"
    }
}
Export-ModuleMember -function Publish-Policy




function Remove-Role {
	<#
	.SYNOPSIS
		Deletes an IAM role entirely, by first deleting all inline IAM policies and then detaching all IAM managed policies.
	.PARAMETER RoleName
		The name of the role.
	.PARAMETER Region
		The region.
	.PARAMETER Force
		Optional flag that when provided will suppress confirmations.
	.EXAMPLE
		Remove-Role -RoleName foo-role -Region ap-southeast-2 -Force
	#>
	param
	(
		[Parameter(Mandatory=$true)]
		[string] 
		$RoleName,

		[Parameter(Mandatory=$true)]
		[string] 
		$Region,

		[Parameter(Mandatory=$false)]
		[switch] 
		$Force
	)	
	Write-Verbose "Attempting to remove role..."
	Write-Verbose "   Checking if role exists..."
	Write-Verbose "   RoleName : [$RoleName]"
	Write-Verbose "   Region : [$Region]"
	Write-Verbose "   Force : [$Force]"
	$existingRole = Get-Role -RoleName $RoleName
	Write-Verbose "   response : [$existingRole]"
	if (!$existingRole) {
		Write-Verbose "   Role doesn't exist!"
		return
	}
	Write-Verbose "   Role exists, attempting to delete..."
	Write-Verbose "   Attempting to detach role from all instance profiles..."	
	Get-IAMInstanceProfileForRole -RoleName $RoleName | Remove-IAMRoleFromInstanceProfile -RoleName $RoleName -Force:$Force
	Write-Verbose "   Attempting to detach all managed policies..."	
	Get-IAMAttachedRolePolicyList -RoleName $RoleName | Unregister-IAMRolePolicy -RoleName $RoleName
	Write-Verbose "   Attempting to delete all inline policies..."	
	$inlinePolicies = Get-IAMRolePolicyList -RoleName $RoleName
	foreach ($inlinePolicy in $inlinePolicies) {
		Write-Verbose "   Deleting : [$inlinePolicy]"	
		Remove-IAMRolePolicy -RoleName $RoleName -PolicyName $inlinePolicy -Force:$Force
	} 
	Write-Verbose "   Attempting to remove the role..."	
	Remove-IAMRole -RoleName $RoleName -Force:$Force
}
Export-ModuleMember -function Remove-Role


