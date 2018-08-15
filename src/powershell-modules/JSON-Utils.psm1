#Requires -Version 5
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"


function Get-JsonObject {
	<#
	.SYNOPSIS
		Loads the contents of the given file and attempts to return it as a JSON object.
	.PARAMETER Filename
		The file to read the contents from.
	.OUTPUTS
		The converted JSON object.
	.EXAMPLE
		$myJson = Get-Json -Filename "foo.json" 
	#>
	param
	(
		[Parameter(Mandatory=$true)]
		[string] 
		$Filename
	)
	Write-Verbose "Attempting to load contents of file..."
	Write-Verbose "   Filename : $Filename"
	$fileContentsRaw = Get-Content -Path $Filename
	Write-Verbose "   Attempting to parse contents as JSON..."
	$fileContentsJson = $fileContentsRaw | ConvertFrom-Json
	return $fileContentsJson
}
Export-ModuleMember -function Get-JsonObject



function ConvertTo-JsonDeep {
	<#
	.SYNOPSIS
		Converts the given JSON object to a JSON formatted string with a depth of 99.
	.PARAMETER JsonObject
		The JSON object you wish to convert.
	.OUTPUTS
		A JSON formatted string.
	.EXAMPLE
		$myJson = ConvertTo-DeepJson -JsonObject (Get-Content -Path "foo.json" | ConvertFrom-Json) 
	#>
	param
	(
		[Parameter(Mandatory=$true)]
		[PSObject] 
		$JsonObject
	)
	$jsonString = $JsonObject | ConvertTo-Json -Depth 99
	return $jsonString
}
Export-ModuleMember -function ConvertTo-JsonDeep



function Merge-Json {
	<#
	.SYNOPSIS
		Merges the properties in the source JSON object into the target JSON object.
	.NOTES
		- Only operates at the root level, is not recursive.
		- Will fail if any source property exists in the target object.
	.PARAMETER SourceJson
		The source JSON object.
	.PARAMETER TargetJson
		The target JSON object.
	.OUTPUTS
		The target JSON object.
	.EXAMPLE
		$myJson = Merge-Json -SourceJson (Get-Content -Path "foo.json" | ConvertFrom-Json) -TargetJson (Get-Content -Path "bar.json" | ConvertFrom-Json)
	#>
	param
	(
		[Parameter(Mandatory=$true)]
		[PSObject] 
		$SourceJson,

		[Parameter(Mandatory=$true)]
		[PSObject] 
		$TargetJson
	)
	Write-Verbose "Attempting to merge JSON..."
	Write-Verbose "   SourceJson : [$SourceJson]"
	Write-Verbose "   TargetJson : [$TargetJson]"
	$SourceJson.PSObject.Properties | ForEach-Object {
		$TargetJson | Add-Member -MemberType $_.MemberType -Name $_.Name -Value $_.Value
	}
	Write-Verbose "   Merged successfully"
	return $TargetJson
}
Export-ModuleMember -function Merge-Json


function Assert-PropertiesExist {
	<#
	.SYNOPSIS
		Asserts that the given array of property names exist in the given JSON object.
	.PARAMETER Json
		The JSON object to assert on.
	.PARAMETER Properties
		The names of the properties to assert for, as an array of strings.
	.EXAMPLE
		Assert-PropertiesExist -Json (Get-Content -Path "foo.json" | ConvertFrom-Json) -Properties @("Foo", "Bar")
	#>
	param
	(
		[Parameter(Mandatory=$true)]
		[PSObject] 
		$Json,

		[Parameter(Mandatory=$true)]
		[string[]] 
		$Properties
	)
	Write-Verbose "Asserting that the given properties exist in the JSON object..."
	Write-Verbose "   Json : [$Json]"
	Write-Verbose "   Properties : [$Properties]"
	foreach($property in $properties) {
		if (!$json.PSObject.Properties.Match($property)) {
			throw "The policy JSON is missing the following property : $property"
		}
	}	
	Write-Verbose "   Assertion passed"
}
Export-ModuleMember -function Assert-PropertiesExist
