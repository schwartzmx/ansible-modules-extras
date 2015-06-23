#!powershell
# This file is part of Ansible
#
# Copyright 2015, Phil Schwartz <schwartzmx@gmail.com>
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

$params = Parse-Args $args;

$result = New-Object psobject @{
    win_zip = New-Object psobject
    changed = $false
}

# Check creates to begin
If ($params.creates) {
    If (Test-Path $params.creates) {
        Exit-Json $result "The 'creates' file already exists."
    }
}

# Global flags
$isLeaf = $false
$isContainer = $false

# Check if PSCX is installed
$list = Get-Module -ListAvailable
If (-Not ($list -match "PSCX")) {
    Set-Attr $result.win_zip "pscx_status" "absent"
    $pscxPresent = $false
}
Else {
    $pscxPresent = $true
    Set-Attr $result.win_zip "pscx_status" "present"
}

# Import
Try {
    If ($pscxPresent) {
        Try {
            Import-Module 'C:\Program Files (x86)\Powershell Community Extensions\pscx3\pscx\pscx.psd1'
        }
        Catch {
            Import-Module PSCX
        }
    }
}
Catch {
    Fail-Json $result "Error importing module PSCX"
}

# Get Params (SRC, DEST, TYPE, RM)
# SRC
If ($params.src) {
    $src = $params.src.toString()

    If(Test-Path $src -PathType Leaf) {
        $isLeaf = $true
    }
    ElseIf (Test-Path $src -PathType Container) {
        $lastchar = $src[$src.length-1]
        If (-Not ($lastchar -eq "/" -Or $lastchar -eq "\")) {
            # figure out type of path delimiter provided
            If ($src.split("\").length -eq 1) {
                $src = $src + "/"
            }
            Else {
                $src = $src + "\"
            }
        }
        $isContainer = $true
    }
    Else {
        Fail-Json $result "Specified src: $src is not a valid file or directory"
    }

}
Else {
    Fail-Json $result "missing required argument: src"
}


#RM
If ($params.rm -eq "true" -Or $params.rm -eq "yes"){
    $rm = $true
}
Else {
    $rm = $false
}

#TYPE
If ($params.type -eq "bzip" -Or $params.type -eq "tar" -Or $params.type -eq "gzip") {
    $type = $params.type.toString()

    # Requires PSCX
    If (-Not $pscxPresent) {
        Fail-Json $result "PowerShellCommunityExtensions PowerShell Module (PSCX) is required for extracting non-'.zip' compressed archives."
    }
}
Else {
    $type = "zip"
}

# DEST
If ($params.dest) {
    $dest = $params.dest.toString()

    If ((Test-Path $dest -PathType Container) -And ($type -eq "zip" -Or $type -eq "tar")) {
        Fail-Json $result "Error in dest arg. Please provide the desired zip/tar file name at the end of the path. (C:\Users\Path\Ex.zip)"
    }

    $ext = [System.IO.Path]::GetExtension($dest)
    If (-Not ( $ext -eq ".zip" -Or $ext -eq ".tar")) {
        If ($type -eq "tar") {
            $dest = $dest + ".tar"
        }
        ElseIf ($type -eq "zip") {
            $dest = $dest + ".zip"
        }
    }
    ElseIf ($isLeaf -And -Not(Test-Path $dest -PathType Container) -And ($type -eq "bzip" -Or $type -eq "gzip")){
        If ($type -eq "bzip" -And $ext -ne ".bz2") {
            $dest = $dest + ".bz"
        }
        ElseIf ($type -eq "gzip" -And $ext -ne ".gz") {
            $dest = $dest + ".gz"
        }

    }

}
Else {
    Fail-Json $result "missing required argument: dest"
}

# Compress
Try {
    If ($type -eq "zip") {
        # Use PSCX if it is present, else use the built in PowerShell util
        If ($pscxPresent) {
            # On success Write-Zip writes to std-out. This is the reason for piping to out-null (And also b/c their -Quiet switch won't work).
            # This allows for the try-catch to still catch errors, but not fail on success output.
            Write-Zip -Path $src -OutputPath $dest -Level 9 -IncludeEmptyDirectories | out-null
            $result.changed = $true
        }
        Else {
            # Uses the built-in shell app to copy to a zip archive
            $fileList = Get-ChildItem $src
            Write-Host $null >> $dest # equivalent to `touch $destinationFile`
            $shellApplication = new-object -com shell.application
            $zipPackage = $shellApplication.NameSpace($dest)

            ForEach($file in $fileList) { 
                $zipPackage.CopyHere($file.FullName)
                Start-sleep -milliseconds 500
            }
            $result.changed = $true
        }
    }
    ElseIf ($type -eq "bzip") {
        If ($isLeaf) {
            Write-BZip2 -Path $src | out-null
            Move-Item -Path $src".bz2" -Destination $dest
        }
        ElseIf ($isContainer) {
            Get-ChildItem $src -Recurse | Write-BZip2 | out-null
            Get-ChildItem $src"*.bz2" -Recurse | Move-Item -Destination $dest
        }

        $result.changed = $true
    }
    ElseIf ($type -eq "tar") {
        Write-Tar -Path $src -OutputPath $dest | out-null
        $result.changed = $true
    }
    ElseIf ($type -eq "gzip") {
        If ($isLeaf) {
            Write-GZip -Path $src | out-null
            Move-Item -Path $src".gz" -Destination $dest
        }
        ElseIf ($isContainer) {
            Get-ChildItem $src -Recurse | Write-Gzip | out-null
            Get-ChildItem $src"*.gz" -Recurse | Move-Item -Destination $dest
        }

        $result.changed = $true
    }
    Else {
        Fail-Json $result "An error occured when checking param: type for compression creation"
    }

    If ($rm){
        Try {
            Remove-Item -Path $src -Force -Recurse
            Set-Attr $result.win_zip "rm" "removed $src"
        }
        Catch {
            Fail-Json $result "Error removing $src"
        }
    }
}
Catch {
    $directory = [System.IO.Path]::GetDirectoryName($dest)
    If (-Not (Test-Path -Path $directory -PathType Container)) {
        Fail-Json $result "Directory: $directory does not exist in the dest provided."
    }
    Else {
        Fail-Json $result "Error compressing $src to $dest."
    }
}

# Fixes a fail error message (when the task actually succeeds) for a "Convert-ToJson: The converted JSON string is in bad format"
# This happens when JSON is parsing a string that ends with a "\", which is possible when specifying a directory to download to.
# This catches that possible error, before assigning the JSON $result
If ($src[$src.length-1] -eq "\") {
    $src = $src.Substring(0, $src.length-1)
}
If ($dest[$dest.length-1] -eq "\") {
    $dest = $dest.Substring(0, $dest.length-1)
}
Set-Attr $result.win_zip "src" $src.toString()
Set-Attr $result.win_zip "dest" $dest.toString()
Set-Attr $result.win_zip "rm" $rm.toString()
Set-Attr $result.win_zip "type" $type.toString()

Exit-Json $result;

