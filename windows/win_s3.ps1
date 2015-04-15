#!powershell
# This file is part of Ansible
#
# Copyright 2014, Phil Schwartz <schwartzmx@gmail.com>
#
# Ansible is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Ansible is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Ansible.  If not, see <http://www.gnu.org/licenses/>.

# WANT_JSON
# POWERSHELL_COMMON

$url = "http://sdk-for-net.amazonwebservices.com/latest/AWSToolsAndSDKForNet.msi"
$sdkdest = "C:\AWSPowerShell.msi"

# Global flags
$isLeaf = $false
$isContainer = $false
$rm = $false

$params = Parse-Args $args;

$result = New-Object psobject @{
    win_s3 = New-Object psobject
    changed = $false
}

# Check if AWS SDK is installed
$list = Get-Module -ListAvailable
# If not download it and install
If (-Not ($list -match "AWSPowerShell")){
    Try{
        $client = New-Object System.Net.WebClient
        $client.DownloadFile($url, $sdkdest)
    }
    Catch {
        Fail-Json $result "Error downloading AWS-SDK from $url and saving as $sdkdest"
    }
    Try{
        Start-Process -FilePath msiexec.exe -ArgumentList "/i $sdkdest /qb" -Verb Runas -PassThru -Wait | out-null
    }
    Catch {
        Fail-Json $result "Error installing $sdkdest"
    }
    Set-Attr $result.win_s3 "aws_sdk_status" "aws_sdk was installed"
}
Else {
    Set-Attr $result.win_s3 "aws_sdk_status" "present"
}

# Import Module
Try {
    Try {
        Import-Module 'C:\Program Files (x86)\AWS Tools\PowerShell\AWSPowerShell\AWSPowerShell.psd1'
    }
    Catch {
        Import-Module AWSPowerShell
    }
}
Catch {
    Fail-Json $result "Error importing module AWSPowerShell"
}

# ---Get Parameters--- (BUCKET, KEY, LOCAL, RM, METHOD, ACCESS_KEY, SECRET_KEY)
# Credentials - must come before any AWS access methods (like Test-S3Bucket)
If ($params.access_key -And $params.secret_key) {
    $access_key = $params.access_key.toString()
    $secret_key = $params.secret_key.toString()

    Set-AWSCredentials -AccessKey $access_key -SecretKey $secret_key -StoreAs default
}
ElseIf ($params.access_key -Or $params.secret_key) {
    If ($params.access_key){
        Fail-Json $result "Missing credential: secret_key"
    }
    Else {
        Fail-Json $result "Missing credential: access_key"
    }
}

# BUCKET
If ($params.bucket) {
    $bucket = $params.bucket.toString()

    # Test that the bucket exists
    Try{
        Test-S3Bucket -BucketName $bucket.toString()
    }
    Catch {
        Fail-Json $result "Error. Bucket: $bucket not found. Or authorization to access bucket failed."
    }
}
Else {
    Fail-Json $result "missing required argument: bucket"
}

# KEY
If ($params.key) {
    $key = $params.key.toString()
}
Else {
    Fail-Json $result "missing required argument: key"
}

# RM (remove local file after successful upload)
If ($params.rm -eq "true" -Or $params.rm -eq "yes") {
    $rm = $true
}
Else {
    $rm = $false
}

# METHOD
If ($params.method) {
    $method = $params.method.toString()

    # Check for valid method
    If (-Not ($method -eq "download" -Or $method -eq "upload")){
        Fail-Json $result "Invalid method parameter entered: $method"
    }
}
Else {
    Fail-Json $result "missing required argument: method"
}

# OVERWRITE
If ($params.overwrite -eq "true" -Or $params.overwrite -eq "yes") {
    $overwrite = $true
}
Else {
    $overwrite = $false
}

# LOCAL (file)
If ($params.local) {
    $local = $params.local.toString()

    # Only test upload because for download method the file is created on download only the path must exist
    If ($method -eq "upload"){
        If (Test-Path $local -PathType Leaf){
            $isLeaf = $true
        }
        ElseIf (Test-Path $local -PathType Container){
            $isContainer = $true
        }
        Else{
            Fail-Json $result "Local file or directory: $local does not exist"
        }
    }
    # Test that the path to the basename exists, since the file or folder will be created on download
    ElseIf ($method -eq "download") {
        $dir = [IO.Path]::GetDirectoryName($local)

        If (-Not (Test-Path $dir -PathType Container)){
            Fail-Json $result "The path to the local file/directory to save to does not exist. Ensure $dir exists."
        }

        If ($local[$local.length-1] -eq "/" -Or $local[$local.length-1] -eq "\") {
            Fail-Json $result "When downloading a file/folder, please specify the save name of the file/folder as well as the valid path, for example: C:\Path\To\Save\To\NAME.zip or C:\Path\To\Save\DIRECTORYNAME"
        }


        If ($overwrite -eq $false -And (Test-Path $local -PathType Leaf)) {
           Exit-Json $result "The file already exists."
        }
    }
}
Else {
    Fail-Json $result "missing required argument: local"
}


# Upload file or Directory
If ($method -eq "upload"){
    #Upload file
    If ($isLeaf){
        Try{
            # If a key-prefix is entered instead of a full key (including file name), append local file name to key for upload
            If ($key[$key.length-1] -eq "/" -Or $key[$key.length-1] -eq "\") {
                $basename = Split-Path $local -Leaf
                Write-S3Object -BucketName $bucket -Key $key$basename -File $local
                $result.changed = $true
            }
            Else {
                Write-S3Object -BucketName $bucket -Key $key -File $local
                $result.changed = $true
            }

            If ($rm -eq $true){
                Remove-Item -Path $local -Force
            }
        }
        Catch {
            Fail-Json $result "Error uploading $local and saving as $buckey$key"
        }
    }
    # Upload all files within a directory
    # * When uploading an entire directory, the key specified must just be the key-prefix so that the file names will be appended
    ElseIf ($isContainer){
        Try {
            If (-Not ($key[$key.length-1] -eq "/" -Or $key[$key.length-1] -eq "\")){
                Fail-Json $result "Invalid key-prefix entered for uploading an entire directory. Example key: 'Path/To/Save/To/'"
            }

            Write-S3Object -BucketName $bucket -Folder $local -KeyPrefix $key -Recurse
            $result.changed = $true

            If ($rm -eq $true){
                Remove-Item -Path $local -Force -Recurse
            }
        }
        Catch {
            Fail-Json $result "Error occured when uploading files from $local to Bucket: $bucket -> Key: $key"
        }
    }
}
# Download file
ElseIf ($method -eq "download"){
    # If not a key prefix, then it's just a file
    If (-Not ($key[$key.length-1] -eq "/" -Or $key[$key.length-1] -eq "\")){
        Try{
            Read-S3Object -BucketName $bucket -Key $key -File $local
            $result.changed = $true
        }
        Catch {
            Fail-Json $result "Error downloading Bucket: $bucket -> Key: $key and saving as $local"
        }
    }
    # Key prefix (downloading a directory)
    Else {
        Try{
            Read-S3Object -BucketName $bucket -KeyPrefix $key -Folder $local
            $result.changed = $true
        }
        Catch {
            Fail-Json $result "Error in downloading virtual dir Bucket: $bucket -> Key: $key and saving as $local.  Ensure the path exists and ensure credentials are authorized for access."
        }
    }
}
Else {
    Fail-Json $result "An invalid method was trying to be carried out"
}


Set-Attr $result.win_s3 "bucket" $bucket.toString()
Set-Attr $result.win_s3 "key" $key.toString()
Set-Attr $result.win_s3 "method" $method.toString()

# Fixes a fail error message (when the task actually succeeds) for a "Convert-ToJson: The converted JSON string is in bad format"
# This happens when JSON is parsing a string that ends with a "\", which is possible when specifying a directory to download to.
# This catches that possible error, before assigning the JSON $result
If ($local[$local.length-1] -eq "\") {
    $local = $local.Substring(0, $local.length-1)
}
Set-Attr $result.win_s3 "local" $local.toString()
Set-Attr $result.win_s3 "rm" $rm.toString()

Exit-Json $result;
