#Requires -Version 5
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module "$PSScriptRoot/JSON-Utils.psm1"


function Get-Stack {
	<#
	.SYNOPSIS
		Attempts to find a Cloudformation stack with the given name in the given region.
	.PARAMETER StackName
		The name of the stack to match with.
	.PARAMETER Region
		The region to search in.
	.OUTPUTS
		Returns the matched [Amazon.CloudFormation.Model.Stack] object, else null.
	.EXAMPLE
		$myStack = Get-Stack -StackName foo-stack -Region ap-southeast-2
	#>
	param
	(
		[Parameter(Mandatory=$true)]
		[string] 
		$StackName,

		[Parameter(Mandatory=$true)]
		[string] 
		$Region
	)	
	try {
		Write-Verbose "Attempting to find Cloudformation stack by name and region..."
		Write-Verbose "   StackName : [$StackName]"
		Write-Verbose "   Region : [$Region]"
		$matchedStack = Get-CFNStack -StackName $StackName -Region $Region 
		Write-Verbose "   Stack found!"
		return $matchedStack
	} catch [System.InvalidOperationException] {
		Write-Verbose "   Stack not found!"
		return $null		
	} catch {
		Write-Error "Error finding Cloudformation stack by name : $StackName"
		throw
	}
}
Export-ModuleMember -function Get-Stack




function Test-Template {
	<#
	.SYNOPSIS
		Submits the given Cloudformation template to the AWS Test-CFNTemplate CmdLet.
	.PARAMETER TemplateBody
		The body of the template to test, as JSON formatted string.
	.EXAMPLE
		Test-Template -TemplateBody "{}" 
	#>
	param
	(
		[Parameter(Mandatory=$true)]
		[string] 
		$TemplateBody
	)
	Write-Verbose "Testing template..."
	Write-Verbose "   TemplateBody : [$TemplateBody]"
	Write-Verbose "   Submitting template to AWS..."
	$validationResponse = Test-CFNTemplate -TemplateBody $TemplateBody
	$capabilitiesReason = $validationResponse.Capabilities
	$description = $validationResponse.Description
	Write-Verbose "   capabilitiesReason : [$capabilitiesReason]"
	Write-Verbose "   description : [$description]"
}
Export-ModuleMember -function Test-Template




function Wait-ChangeSetStatus {
	<#
	.SYNOPSIS
		Polls the given Cloudformation change set for a success status, for the given max seconds.
	.PARAMETER ChangeSetName
		The name of the change set to poll.
	.PARAMETER StackName
		The name of the stack the change set belongs to.
	.PARAMETER MaxSecondsToWait
		The optional max number of seconds to poll until a timeout error is thrown (default is 30).
	.OUTPUTS
		True if the status indicates success within the given max time, False if the status indicates 'no changes' within the given max time, otherwise an error is raised with the status details.
	.EXAMPLE
		$success = Wait-ChangeSetStatus -ChangeSetName my-stack-20180329-1300 -StackName my-stack -MaxSecondsToWait 10
	#>
	param
	(
		[Parameter(Mandatory=$true)]
		[string] 
		$ChangeSetName,

		[Parameter(Mandatory=$true)]
		[string] 
		$StackName,

		[Parameter(Mandatory=$false)]
		[int] 
		$MaxSecondsToWait = 30
	)
	$acceptedStatus = "CREATE_COMPLETE"
	$acceptedExecutionStatus = "AVAILABLE"
	$currentSeconds = 0
	Write-Verbose "Polling the change set status..."
	Write-Verbose "   ChangeSetName : [$ChangeSetName]"
	Write-Verbose "   StackName : [$StackName]"
	Write-Verbose "   MaxSecondsToWait : [$MaxSecondsToWait]"
	Write-Verbose "   acceptedStatus : [$acceptedStatus]"
	Write-Verbose "   acceptedExecutionStatus : [$acceptedExecutionStatus]"
	while($currentSeconds -lt $MaxSecondsToWait) {
		$currentSeconds++		
		$stackChangeSet = Get-CFNChangeSet -ChangeSetName $changeSetName -StackName $stackName
		$changeSetStatus = $stackChangeSet.Status
		$changeSetStatusReason = $stackChangeSet.StatusReason
		$executionStatus = $stackChangeSet.ExecutionStatus
		Write-Verbose "   ...waiting for change set to indicate success..."
		Write-Verbose "   changeSetStatus : [$changeSetStatus]"
		Write-Verbose "   changeSetStatusReason : [$changeSetStatusReason]"
		Write-Verbose "   executionStatus : [$executionStatus]`n"

		if ($changeSetStatus -ne $acceptedStatus -and ($changeSetStatusReason -ne $null -and $changeSetStatusReason.Contains("didn't contain changes"))) {
			Write-Verbose "   Change set indicates 'no changes' - do not execute it." 
			return $false
		}
		if ($changeSetStatus -eq $acceptedStatus -and $executionStatus -eq $acceptedExecutionStatus) {
			Write-Verbose "   Change set indicates success." 
			return $true
		}
		Start-Sleep 2
	}
	if ($changeSetStatus -ne $acceptedStatus -or $executionStatus -ne $acceptedExecutionStatus) {
		throw "   Change set failed! status:[$changeSetStatus] executionStatus:[$executionStatus] reason:[$changeSetStatusReason}"
	}
}
Export-ModuleMember -function Wait-ChangeSetStatus




function Test-StackStatus {
	<#
	.SYNOPSIS
		Tests the given Cloudformation stack status for success, throws if status indicates failure.
	.PARAMETER Stack
		The [Amazon.CloudFormation.Model.Stack] object to test.
	.EXAMPLE
		Test-StackStatus -Stack [Amazon.CloudFormation.Model.Stack]$myStack 
	#>
	param
	(
		[Parameter(Mandatory=$true)]
		[Amazon.CloudFormation.Model.Stack] 
		$Stack
	)
	$stackName = $stack.StackName
	$stackStatus = $stack.StackStatus.Value
	$stackStatusReason = $stack.StackStatusReason
	Write-Verbose "Checking stack status..."
	Write-Verbose "   stackName : [$stackName]"
	Write-Verbose "   stackStatus : [$stackStatus]"
	Write-Verbose "   stackStatusReason : [$stackStatusReason]"
	$badStackStatusKeywords = @("FAIL", "ROLLBACK")
	foreach ($badStackStatusKeyword in $badStackStatusKeywords) {
		if ($stackStatus.Contains($badStackStatusKeyword)) {
			throw "The stack status indicates failure! $stackStatus $stackStatusReason"
		}
	} 
	Write-Verbose "   The stack status indicates success! $stackStatus $stackStatusReason"
}
Export-ModuleMember -function Test-StackStatus




function Publish-Stack {
	<#
	.SYNOPSIS
		If the given Cloudformation stack exists, it is updated via a change set, else it is created.
	.PARAMETER StackName
		The name of the stack.
	.PARAMETER Region
		The region the stack is in.
	.PARAMETER TemplateBody
		The body of the template to test, as JSON formatted string.
	.PARAMETER MaxSecondsToWait
		The optional max number of seconds to poll until a timeout error is thrown (default is 30).
	.OUTPUTS
		The stack ID that was created/updated.
	.EXAMPLE
		$myStackId = Publish-Stack -StackName my-stack -Region ap-southeast-2 -TemplateFilename my-stack.template -MaxSecondsToWait 60
	#>
	param
	(
		[Parameter(Mandatory=$true)]
		[string] 
		$StackName,

		[Parameter(Mandatory=$true)]
		[string] 
		$TemplateBody,

		[Parameter(Mandatory=$true)]
		[string] 
		$Region,

		[Parameter(Mandatory=$false)]
		[int] 
		$MaxSecondsToWait = 30
	)
	$changeSetName = "$StackName-$(Get-Date -format yyyyMMdd-HHmmss)"
	Write-Verbose "Attempting to publish stack..."
	Write-Verbose "   Testing the template..."
	Test-Template -TemplateBody $TemplateBody
	Write-Verbose "   Checking if stack exists..."
	Write-Verbose "   StackName : [$StackName]"
	Write-Verbose "   changeSetName : [$changeSetName]"
	$existingStack = Get-Stack -StackName $StackName -Region $Region
	Write-Verbose "   response : [$existingStack]"
	Write-Verbose "   The following role template will be submitted to CFN..."
	Write-Verbose $TemplateBody

	if ($existingStack) {
		Write-Verbose "   Stack exists! Attempting to update via change set..."
		New-CFNChangeSet -ChangeSetName $changeSetName -StackName $StackName -Capability @("CAPABILITY_NAMED_IAM") -TemplateBody $TemplateBody -Region $Region
		$changeSetSuccess = Wait-ChangeSetStatus -ChangeSetName $changeSetName -StackName $StackName -MaxSecondsToWait $MaxSecondsToWait
		if ($changeSetSuccess) {
			Write-Verbose "   Attempting to execute change set..."
			Start-CFNChangeSet -ChangeSetName $changeSetName -StackName $StackName -Region $Region
			Write-Verbose "   Waiting for stack update..."
			$stack = Wait-CFNStack -StackName $StackName -Timeout $MaxSecondsToWait -Region $Region
			Test-StackStatus -Stack $stack
			Write-Verbose "   Stack was updated!"
			Write-Verbose "   stackId : [$($existingStack.StackId)]"
		} else {
			Write-Verbose "   Stack was unchanged!"			
			Write-Verbose "   stackId : [$($existingStack.StackId)]"
		}
		return $existingStack.StackId
	}
	Write-Verbose "   Stack doesn't exist! Attempting to create..."
	New-CFNStack -StackName $StackName -Capability @("CAPABILITY_NAMED_IAM") -TemplateBody $TemplateBody -Region $Region
	Write-Verbose "   Waiting for stack creation..."
	$stack = Wait-CFNStack -StackName $StackName -Timeout $MaxSecondsToWait -Region $Region
	Test-StackStatus -Stack $stack
	Write-Verbose "   Stack was created!"
	Write-Verbose "   stackId : [$($stack.StackId)]"
	return $stack.StackId
}
Export-ModuleMember -function Publish-Stack
