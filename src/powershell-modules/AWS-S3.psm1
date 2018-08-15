#Requires -Version 5
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module "$PSScriptRoot/JSON-Utils.psm1"


# https://docs.aws.amazon.com/AmazonS3/latest/dev/acl-overview.html
enum CannedAclName {
	Private
	PublicRead
	PublicReadWrite
	AuthenticatedRead
	AwsExecRead
	BucketOwnerRead
	BucketOwnerFullControl
	LogDeliveryWrite
}
$CannedAclNames = @{
    [CannedAclName]::Private = "private";
    [CannedAclName]::PublicRead = "public-read";
    [CannedAclName]::PublicReadWrite = "public-read-write";
    [CannedAclName]::AuthenticatedRead = "authenticated-read";
    [CannedAclName]::AwsExecRead = "aws-exec-read";
    [CannedAclName]::BucketOwnerRead = "bucket-owner-read";
    [CannedAclName]::BucketOwnerFullControl = "bucket-owner-full-control";
    [CannedAclName]::LogDeliveryWrite = "log-delivery-write"
}


function Get-Bucket {
	<#
	.SYNOPSIS
		Attempts to find an S3 bucket with the given name in the given region.
	.PARAMETER BucketName
		The name of the bucket to match with.
	.PARAMETER Region
		The region to search in.
	.OUTPUTS
		Returns the matched [Amazon.S3.Model.S3Bucket] object, else null.
	.EXAMPLE
		$myBucket = Get-Bucket -BucketName foo-bucket -Region ap-southeast-2
	#>
	param
	(
		[Parameter(Mandatory=$true)]
		[string] 
		$BucketName,

		[Parameter(Mandatory=$true)]
		[string] 
		$Region
	)	
	try {
		Write-Verbose "Attempting to find S3 bucket by name and region..."
		Write-Verbose "   BucketName : [$BucketName]"
		Write-Verbose "   Region : [$Region]"
		$bucket = Get-S3Bucket -BucketName $BucketName -Region $Region
		if (!$bucket) {
			Write-Verbose "   Bucket not found!"
			return $null		
		}
		Write-Verbose "   Bucket found!"
		return $bucket
	} catch [System.InvalidOperationException] {
		Write-Verbose "   Bucket not found!"
		return $null		
	} catch {
		Write-Error "Error finding S3 bucket : $BucketName"
		throw
	}	
}
Export-ModuleMember -function Get-Bucket


function Add-Bucket {
	<#
	.SYNOPSIS
		Attempts to create a new S3 bucket with the given details.
	.PARAMETER BucketName
		The name of the bucket to create.
	.PARAMETER CannedACLName
		The name of the canned ACL to assign the bucket.
	.PARAMETER Region
		The region to create the bucket in.
	.EXAMPLE
		Add-Bucket -BucketName foo-bucket -CannedACLName LogDeliveryWrite -Region ap-southeast-2
	#>
	param
	(
		[Parameter(Mandatory=$true)]
		[string] 
		$BucketName,

		[Parameter(Mandatory=$true)]
		[CannedAclName] 
		$CannedACLName,

		[Parameter(Mandatory=$true)]
		[string] 
		$Region
	)
	$cannedAclNameValue = $CannedAclNames[$CannedACLName]	
	Write-Verbose "Attempting to create a new S3 bucket..."
	Write-Verbose "   BucketName : [$BucketName]"
	Write-Verbose "   CannedACLName : [$CannedACLName]"
	Write-Verbose "   cannedAclNameValue : [$cannedAclNameValue]"
	Write-Verbose "   Region : [$Region]"
	New-S3Bucket -BucketName $BucketName -CannedACLName $cannedAclNameValue -Region $Region
	Write-Verbose "   Bucket created!"
}
Export-ModuleMember -function Add-Bucket



function Write-BucketPolicy {
	<#
	.SYNOPSIS
		Sets the given S3 bucket's policy with the given policy document.
		If a bucket policy exists, it is overwritten with the given policy document.
	.PARAMETER BucketName
		The name of the bucket to effect.
	.PARAMETER PolicyDocumentFilename
		The name of the file containing the S3 policy document.
	.PARAMETER AccountNumber
		The target account of the bucket.
	.EXAMPLE
		Write-BucketPolicy -BucketName foo-bucket -PolicyDocumentFilename foo-bucket-policy.json -AccountNumber 1234567890
	#>
	param
	(
		[Parameter(Mandatory=$true)]
		[string] 
		$BucketName,

		[Parameter(Mandatory=$true)]
		[string] 
		$PolicyDocumentFilename,

		[Parameter(Mandatory=$true)]
		[string] 
		$AccountNumber
	)	
	$policyContent = Get-Content -Path $PolicyDocumentFilename -Raw
	$policyContent = $policyContent.Replace("<||AwsAccountNumber||>", $AccountNumber)
	Write-Verbose "Attempting to write S3 bucket policy..."
	Write-Verbose "   BucketName : [$BucketName]"
	Write-Verbose "   PolicyDocumentFilename : [$PolicyDocumentFilename]"
	Write-Verbose "   policyContent : $policyContent"
	Write-S3BucketPolicy -BucketName $BucketName -Policy $policyContent
	Write-Verbose "   Bucket policy written!"
}
Export-ModuleMember -function Write-BucketPolicy


