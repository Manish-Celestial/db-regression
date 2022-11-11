param (
    [Parameter(Mandatory = $true)]
    [string]
    $scriptName, # e.g. "db-test-ps1"

    [Parameter(Mandatory = $false)]
    [boolean]
    $scriptNameIsFullPath = $false, # Defaults to presuming the script is in the DB Regression Repo in the Scripts directory

    [Parameter(Mandatory = $false)]
    [string]
    $scriptParameters, # e.g. "-Compile 0 -Test 1" Note that Boolean parameters must be passed as 1 or 0, not $true or $false. The SSM Command cannot pass booleans through to the script

    [Parameter(Mandatory = $true)]
    [string]
    $comment, # e.g. "Compiling and running tests"

    [Parameter(Mandatory = $true)]
    [string]
    $dbtype,

    [Parameter(Mandatory = $true)]
    [string]
    $OutputS3BucketName,

    [Parameter(Mandatory = $true)]
    [string]
    $OutputS3KeyPrefix,

    [Parameter(Mandatory = $true)]
    [string]
    $LansaVersion
)

$ErrorActionPreference = "Stop"

# Mapping of databases to appropriate path
$DatabaseType_SystemRootPath = @{
    "AZURESQL" = "C:\Program Files (x86)\AZURESQL";
    "MSSQLS" = "C:\Program Files (x86)\LANSA";
    "ORACLE" = "C:\Program Files (x86)\ORACLE";
    "SQLANYWHERE" = "C:\Program Files (x86)\SQLANYWHERE";
    "MYSQL" = "C:\Program Files (x86)\MySQL"
}

$root_directory = $DatabaseType_SystemRootPath[$dbtype]

$instance_id = ((Get-EC2Instance -Filter @( `
                                    @{Name = "tag:LansaVersion"; Values=$LansaVersion}, `
                                    @{Name= "tag:aws:cloudformation:stack-name"; Values="DB-Regression-VM-$LansaVersion"}) `
                                    ).Instances `
                                ).InstanceId `

$ScriptPath = $scriptName
if (-not $scriptNameIsFullPath) {
    $ScriptPath = "$root_directory\LANSA\VersionControl\Scripts\$scriptName"
}

$localComment = "$comment using $dbtype"
Write-Host
Write-Host "$localComment"
Write-Host "Executing $ScriptPath $ScriptParameters on VM $lansaVersion"

$runPSCommandID = (Send-SSMCommand `
        -DocumentName "AWS-RunPowerShellScript" `
        -Comment $localComment `
        -Parameter @{'commands' = @("try { & '$ScriptPath' $scriptParameters} catch {exit 1}" )} `
        -Target @(@{Key="tag:aws:cloudformation:stack-name"; Values = "DB-Regression-VM-$LansaVersion"}, @{Key="tag:LansaVersion"; Values = "$LansaVersion"}) `
        -OutputS3BucketName $OutputS3BucketName `
        -OutputS3KeyPrefix $OutputS3KeyPrefix/$dbtype).CommandId

Write-Host "`nThe CommandID is: $runPSCommandID`n"

# Function to read the logs (from the S3 bucket) generated by running the Send-SSMCommand and printing it out to the Azure DevOps console
function send-ssm-output-to-console {
    Write-Host( "Remove existing log files from temporary directory...")
    $LogDir = "s3_logs"
    if ( Test-Path -Path $LogDir ) {
        Get-ChildItem -Path $LogDir | Out-Default | Write-Host
        Get-ChildItem -Path $LogDir | foreach {$_.Delete()} | Out-Default | Write-Host
    }

    # This will download the AWS Systems Manager log file(s) locally at the location specified on the "Folder" flag
    Read-S3Object -BucketName $OutputS3BucketName `
        -KeyPrefix "$OutputS3KeyPrefix/$dbtype/$runPSCommandID/$instance_id/awsrunPowerShellScript/0.awsrunPowerShellScript" `
        -Folder $LogDir | Out-Default | Write-Host # This is on the agent, and not the local machine '

    if ( (Get-ChildItem -Path $LogDir | Measure-Object).count -le 0) {
        throw "There are no log files. VM probably not found"
    }

    # This will get all types of logs (expected types: stderr, for failure and stdout if successful) and print them to the console
    Get-ChildItem $LogDir | ForEach-Object {
        $content = Get-Content -Raw $_.FullName
        Write-Host "`n###################### - Displaying logs for: $($_.Name) - ######################`n"
        Write-Host $content
        Write-Host "`n###################### - END - ######################`n"
    }  | Out-Default | Write-Host

    Write-Host "`nThe logs can also be found here: $OutputS3BucketName/$OutputS3KeyPrefix/$dbtype/$runPSCommandID/`n"
}

# The retry/timeout logic in case the script doesn't run; it will halt the execution right away if status is "Failed"
$RetryCount = 90
while(((Get-SSMCommand -CommandId $runPSCommandID).Status -ne "Success") -and ($RetryCount -gt 0)) {

    Write-Host "Please wait. The logs will be displayed after the execution.`n"

    Start-Sleep 20 # Checking every 20 seconds

    $RetryCount -= 1

    if(((Get-SSMCommand -CommandId $runPSCommandID).Status).Value -eq "Failed") {
        send-ssm-output-to-console # This is a function
        throw "$scriptName execution for $dbtype has failed!"
    }
}

# The actual timeout/halting of execution when timeout occures
if($RetryCount -le 0) {
    send-ssm-output-to-console # This is a function
    throw "Timeout: 30 minutes expired waiting for the script to start."
}

# And when nothing fails, fetch and write the logs
send-ssm-output-to-console # This is a function
